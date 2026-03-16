import CSearchfs
import Foundation

// MARK: - SearchfsError

enum SearchfsError: LocalizedError {
    case volumeNotSupported(String)
    case searchFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .volumeNotSupported(vol):
            return "Volume does not support catalog search: \(vol)"
        case let .searchFailed(vol, err):
            return "Search failed on \(vol): \(String(cString: strerror(err)))"
        }
    }
}

// MARK: - SearchfsService

/// Actor-based service for fast filename search using the searchfs() syscall.
///
/// searchfs() reads the APFS/HFS+ catalog B-tree directly at kernel level,
/// providing complete filename search with no Spotlight index dependency.
/// It only supports case-insensitive substring matching — glob patterns
/// (*, ?) are handled via post-filtering in Swift.
///
/// Used for external/non-Spotlight-indexed volumes where Spotlight has no
/// coverage. For Spotlight-indexed volumes, NSMetadataQuery provides better
/// results (user-relevant, content-aware).
actor SearchfsService: SearchfsServiceProtocol {
    private var activeTask: Task<Void, Never>?

    // MARK: - Public API

    func searchNonIndexedVolumes(
        query: String,
        maxResults: UInt32 = 10_000
    ) -> AsyncStream<[FileItem]> {
        cancelActiveSearch()

        let volumes = Self.nonIndexedSearchfsVolumes()
        guard !volumes.isEmpty else {
            return AsyncStream { $0.finish() }
        }

        let searchPattern = Self.extractSubstring(from: query)
        let globRegex = GlobPattern.buildRegex(from: query)

        let (stream, continuation) = AsyncStream.makeStream(of: [FileItem].self)

        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for volume in volumes {
                    group.addTask {
                        await Self.searchVolume(
                            volumePath: volume,
                            pattern: searchPattern,
                            globRegex: globRegex,
                            maxResults: maxResults,
                            continuation: continuation
                        )
                    }
                }
            }
            continuation.finish()
        }

        activeTask = task
        continuation.onTermination = { _ in
            task.cancel()
        }

        return stream
    }

    func search(
        query: String,
        volumePath: String,
        maxResults: UInt32 = 10_000
    ) -> AsyncStream<[FileItem]> {
        cancelActiveSearch()

        let searchPattern = Self.extractSubstring(from: query)
        let globRegex = GlobPattern.buildRegex(from: query)

        let (stream, continuation) = AsyncStream.makeStream(of: [FileItem].self)

        let task = Task {
            await Self.searchVolume(
                volumePath: volumePath,
                pattern: searchPattern,
                globRegex: globRegex,
                maxResults: maxResults,
                continuation: continuation
            )
            continuation.finish()
        }

        activeTask = task
        continuation.onTermination = { _ in
            task.cancel()
        }

        return stream
    }

    func cancelActiveSearch() {
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: - Volume Discovery

    /// Returns mount paths of non-Spotlight-indexed volumes that support searchfs().
    ///
    /// These are typically external drives (USB, Thunderbolt) formatted as APFS or
    /// HFS+ that Spotlight hasn't indexed. searchfs() provides complete filename
    /// search on these volumes where Spotlight has no coverage.
    ///
    /// The boot volume ("/") and its data partition ("/System/Volumes/Data") are
    /// always Spotlight-indexed and excluded — Spotlight provides better results
    /// there (user-relevant, content-aware).
    private static func nonIndexedSearchfsVolumes() -> [String] {
        var volumes: [String] = []

        guard let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) else {
            return volumes
        }

        for url in volumeURLs {
            let path = url.path

            // Skip the boot volume and its data partition — always Spotlight-indexed.
            if path == "/" || path == "/System/Volumes/Data" {
                continue
            }

            // Only include volumes that support searchfs (APFS/HFS+).
            guard csearchfs_volume_supports_searchfs(path) else {
                continue
            }

            // Skip volumes that have a Spotlight index.
            let spotlightDir = (path as NSString).appendingPathComponent(".Spotlight-V100")
            if FileManager.default.fileExists(atPath: spotlightDir) {
                continue
            }

            volumes.append(path)
        }

        return volumes
    }

    // MARK: - Search Execution

    /// Context passed through the C callback's void* pointer.
    /// Accumulates matched paths and flushes them as FileItem batches
    /// directly to the AsyncStream continuation, so the UI receives
    /// results incrementally during the (potentially long) catalog scan.
    private final class CallbackContext {
        let continuation: AsyncStream<[FileItem]>.Continuation
        let globRegex: NSRegularExpression?
        var paths: [String] = []
        let batchThreshold: Int

        init(
            continuation: AsyncStream<[FileItem]>.Continuation,
            globRegex: NSRegularExpression?,
            batchThreshold: Int = 50
        ) {
            self.continuation = continuation
            self.globRegex = globRegex
            self.batchThreshold = batchThreshold
        }

        /// Flush accumulated paths: convert to FileItems, yield, clear buffer.
        func flush() {
            guard !paths.isEmpty else { return }

            var items: [FileItem] = []
            for path in paths {
                let url = URL(fileURLWithPath: path)
                let filename = url.lastPathComponent

                if let globRegex, !GlobPattern.matches(filename, regex: globRegex) {
                    continue
                }

                if let item = FileItem.create(from: url) {
                    items.append(item)
                }
            }

            if !items.isEmpty {
                continuation.yield(items)
            }

            paths.removeAll(keepingCapacity: true)
        }
    }

    /// Searches a single volume and yields batches of FileItems to the continuation.
    ///
    /// The C callback accumulates paths and flushes them every `batchThreshold`
    /// matches. This ensures the UI receives results within seconds even when
    /// the full volume scan takes over a minute.
    private static func searchVolume(
        volumePath: String,
        pattern: String,
        globRegex: NSRegularExpression?,
        maxResults: UInt32,
        continuation: AsyncStream<[FileItem]>.Continuation
    ) async {
        guard !Task.isCancelled else { return }
        guard !pattern.isEmpty else { return }

        await Task.detached {
            let ctx = CallbackContext(
                continuation: continuation,
                globRegex: globRegex,
                batchThreshold: 50
            )
            let unmanaged = Unmanaged.passRetained(ctx)
            let opaquePtr = unmanaged.toOpaque()
            defer { unmanaged.release() }

            csearchfs_search(
                volumePath,
                pattern,
                maxResults,
                true,   // matchFiles
                true,   // matchDirs
                { (path: UnsafePointer<CChar>?, context: UnsafeMutableRawPointer?) -> Bool in
                    guard let context, let path else { return false }
                    if Task.isCancelled { return false }

                    let ctx = Unmanaged<CallbackContext>.fromOpaque(context)
                        .takeUnretainedValue()
                    ctx.paths.append(String(cString: path))

                    // Flush when the batch is full. This converts paths to
                    // FileItems and yields them to the stream immediately,
                    // so the UI updates while the catalog scan continues.
                    if ctx.paths.count >= ctx.batchThreshold {
                        ctx.flush()
                    }

                    return true
                },
                opaquePtr
            )

            // Flush any remaining paths after the search completes.
            ctx.flush()
        }.value
    }

    // MARK: - Query Processing

    /// Extracts the meaningful substring from a query for searchfs.
    /// searchfs only supports substring matching, so we strip glob wildcards
    /// and pass the longest non-wildcard segment.
    ///
    /// Examples:
    ///   "cursor"      → "cursor"
    ///   "*.txt"       → "txt"
    ///   "*_2"         → "_2"
    ///   "report?.pdf" → "report"
    static func extractSubstring(from query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if !GlobPattern.hasWildcards(trimmed) {
            return trimmed
        }

        // Split by wildcard characters and find the longest non-empty segment.
        let segments = trimmed.components(separatedBy: CharacterSet(charactersIn: "*?"))
            .filter { !$0.isEmpty }

        return segments.max(by: { $0.count < $1.count }) ?? trimmed
    }
}
