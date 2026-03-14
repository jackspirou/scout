import Foundation

// MARK: - FSEvents Callback

private func dirSizeEventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let calculator = Unmanaged<DirectorySizeCalculator>.fromOpaque(info).takeUnretainedValue()

    guard let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

    calculator.handleFSEvents(paths: pathsArray, count: numEvents)
}

// MARK: - DirectorySizeCalculator

/// Lazily computes and caches directory sizes in the background.
/// Uses FSEvents to watch cached directories and automatically recomputes
/// when their contents change.
final class DirectorySizeCalculator {
    /// Called on the main thread when a directory size has been computed or updated.
    var onSizeComputed: ((URL, Int64) -> Void)?

    private var cache: [URL: Int64] = [:]
    private var pending: Set<URL> = []
    private let computeQueue = DispatchQueue(label: "scout.dir-size", qos: .utility, attributes: .concurrent)

    /// Debounce timers per-directory to coalesce rapid FSEvents.
    private var recomputeTimers: [URL: Timer] = [:]

    /// The FSEvents stream watching all cached directory paths.
    private var streamRef: FSEventStreamRef?
    /// The set of directory paths currently being watched.
    private var watchedPaths: Set<String> = []

    deinit {
        stopWatching()
        for timer in recomputeTimers.values { timer.invalidate() }
    }

    // MARK: - Public API

    /// Returns the cached size for a directory, or `nil` if not yet computed.
    /// When `nil` is returned, a background computation is kicked off automatically.
    func size(for url: URL) -> Int64? {
        if let cached = cache[url] {
            return cached
        }
        enqueueComputation(for: url)
        return nil
    }

    /// Clears all cached sizes and stops watching.
    func invalidate() {
        stopWatching()
        cache.removeAll()
        pending.removeAll()
        for timer in recomputeTimers.values { timer.invalidate() }
        recomputeTimers.removeAll()
    }

    /// Removes a single entry from the cache.
    func invalidate(url: URL) {
        cache.removeValue(forKey: url)
        pending.remove(url)
        recomputeTimers[url]?.invalidate()
        recomputeTimers.removeValue(forKey: url)
        rebuildStream()
    }

    // MARK: - Computation

    private func enqueueComputation(for url: URL) {
        guard !pending.contains(url) else { return }
        pending.insert(url)

        computeQueue.async { [weak self] in
            let size = Self.computeSize(at: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache[url] = size
                self.pending.remove(url)
                self.rebuildStream()
                self.onSizeComputed?(url, size)
            }
        }
    }

    /// Recursively computes the total size of all files within a directory.
    private static func computeSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileSizeKey, .isRegularFileKey]

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: nil
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isRegularFile == true {
                total += Int64(values.totalFileSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - FSEvents Watching

    /// Rebuilds the FSEvents stream to watch all currently cached directories.
    private func rebuildStream() {
        let newPaths = Set(cache.keys.map(\.path))
        guard newPaths != watchedPaths else { return }

        stopWatching()
        guard !newPaths.isEmpty else { return }

        watchedPaths = newPaths
        let cfPaths = newPaths.map { $0 as CFString } as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            dirSizeEventsCallback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // 1 second latency — good for coalescing bursts
            flags
        ) else { return }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func stopWatching() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
        watchedPaths.removeAll()
    }

    // MARK: - FSEvents Handler

    /// Called from the C callback when changes are detected in watched directories.
    fileprivate func handleFSEvents(paths: [String], count: Int) {
        // Determine which cached directories are affected by these events.
        var affectedURLs: Set<URL> = []
        for i in 0..<count {
            let changedPath = paths[i]
            // Find which cached directory this path falls under.
            for cachedURL in cache.keys {
                let cachedPath = cachedURL.path
                if changedPath.hasPrefix(cachedPath) {
                    affectedURLs.insert(cachedURL)
                }
            }
        }

        // Debounce recomputation per directory (coalesce rapid changes).
        for url in affectedURLs {
            recomputeTimers[url]?.invalidate()
            recomputeTimers[url] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.recomputeTimers.removeValue(forKey: url)
                self.cache.removeValue(forKey: url)
                self.enqueueComputation(for: url)
            }
        }
    }
}
