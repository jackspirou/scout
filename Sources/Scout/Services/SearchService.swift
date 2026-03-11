import AppKit
import Foundation

// MARK: - SearchScope

enum SearchScope: Sendable {
    case currentFolder(URL)
    case subfolder(URL)
    case fullDisk
}

// MARK: - SearchFilter

enum SearchFilter: Sendable {
    case kind(String)
    case sizeGreaterThan(Int64)
    case sizeLessThan(Int64)
    case modifiedAfter(Date)
    case modifiedBefore(Date)
    case hasTag(String)
}

// MARK: - SearchError

enum SearchError: LocalizedError {
    case invalidQuery
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Invalid search query"
        case .queryFailed(let reason):
            return "Search failed: \(reason)"
        }
    }
}

// MARK: - SearchService

/// Actor-based service for file search using Spotlight and custom fuzzy matching.
actor SearchService {

    private var activeQuery: NSMetadataQuery?
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: Duration
    private let fileSystemService: FileSystemService

    init(
        debounceInterval: Duration = .milliseconds(200),
        fileSystemService: FileSystemService = FileSystemService()
    ) {
        self.debounceInterval = debounceInterval
        self.fileSystemService = fileSystemService
    }

    // MARK: - Spotlight Search

    /// Searches for files using NSMetadataQuery (Spotlight) and returns results
    /// as an AsyncStream that emits batches of matching FileItems.
    func search(
        query: String,
        scope: SearchScope,
        filters: [SearchFilter] = []
    ) -> AsyncStream<[FileItem]> {
        // Cancel any active search.
        cancelActiveSearch()

        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            let taskHandle = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                // Apply debounce.
                try? await Task.sleep(for: await self.debounceInterval)

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                await self.executeSpotlightSearch(
                    query: query,
                    scope: scope,
                    filters: filters,
                    continuation: continuation
                )
            }

            continuation.onTermination = { _ in
                taskHandle.cancel()
            }
        }
    }

    // MARK: - Fuzzy Match

    /// Performs fuzzy filename matching within a directory and returns scored results.
    func fuzzyMatch(query: String, in directory: URL) async -> [FileItem] {
        guard !query.isEmpty else { return [] }

        let items: [FileItem]
        do {
            items = try await fileSystemService.contentsOfDirectory(at: directory)
        } catch {
            return []
        }

        let normalizedQuery = query.lowercased()

        var scoredItems: [(FileItem, Int)] = []

        for item in items {
            if let score = fuzzyScore(query: normalizedQuery, target: item.name.lowercased()) {
                scoredItems.append((item, score))
            }
        }

        // Sort by score descending (higher is better).
        scoredItems.sort { $0.1 > $1.1 }

        return scoredItems.map(\.0)
    }

    // MARK: - Cancel

    /// Cancels any active search operation.
    func cancelActiveSearch() {
        debounceTask?.cancel()
        debounceTask = nil

        if let query = activeQuery {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            activeQuery = nil
        }
    }

    // MARK: - Private Implementation

    private func executeSpotlightSearch(
        query queryString: String,
        scope: SearchScope,
        filters: [SearchFilter],
        continuation: AsyncStream<[FileItem]>.Continuation
    ) {
        let metadataQuery = NSMetadataQuery()
        metadataQuery.predicate = buildPredicate(query: queryString, filters: filters)
        metadataQuery.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)
        ]

        switch scope {
        case .currentFolder(let url):
            metadataQuery.searchScopes = [url]
        case .subfolder(let url):
            metadataQuery.searchScopes = [url]
        case .fullDisk:
            metadataQuery.searchScopes = [
                NSMetadataQueryLocalComputerScope
            ]
        }

        // Batch results for performance.
        metadataQuery.notificationBatchingInterval = 0.15

        let observer = SpotlightObserver(continuation: continuation)

        NotificationCenter.default.addObserver(
            observer,
            selector: #selector(SpotlightObserver.queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: metadataQuery
        )

        NotificationCenter.default.addObserver(
            observer,
            selector: #selector(SpotlightObserver.queryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )

        self.activeQuery = metadataQuery

        // NSMetadataQuery must run on the main run loop.
        DispatchQueue.main.async {
            metadataQuery.start()
        }
    }

    private func buildPredicate(query: String, filters: [SearchFilter]) -> NSPredicate {
        var subpredicates: [NSPredicate] = []

        // Main text query: match against display name.
        let nameQuery = query.replacingOccurrences(of: "*", with: "")
        subpredicates.append(
            NSPredicate(
                format: "%K LIKE[cd] %@",
                NSMetadataItemFSNameKey,
                "*\(nameQuery)*"
            )
        )

        for filter in filters {
            switch filter {
            case .kind(let kind):
                subpredicates.append(
                    NSPredicate(
                        format: "%K == %@",
                        NSMetadataItemContentTypeKey,
                        kind
                    )
                )

            case .sizeGreaterThan(let size):
                subpredicates.append(
                    NSPredicate(
                        format: "%K > %lld",
                        NSMetadataItemFSSizeKey,
                        size
                    )
                )

            case .sizeLessThan(let size):
                subpredicates.append(
                    NSPredicate(
                        format: "%K < %lld",
                        NSMetadataItemFSSizeKey,
                        size
                    )
                )

            case .modifiedAfter(let date):
                subpredicates.append(
                    NSPredicate(
                        format: "%K > %@",
                        NSMetadataItemFSContentChangeDateKey,
                        date as NSDate
                    )
                )

            case .modifiedBefore(let date):
                subpredicates.append(
                    NSPredicate(
                        format: "%K < %@",
                        NSMetadataItemFSContentChangeDateKey,
                        date as NSDate
                    )
                )

            case .hasTag(let tag):
                subpredicates.append(
                    NSPredicate(
                        format: "%K CONTAINS %@",
                        "kMDItemUserTags",
                        tag
                    )
                )
            }
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
    }

    /// Computes a fuzzy match score. Returns nil if no match.
    /// Higher scores indicate better matches.
    private func fuzzyScore(query: String, target: String) -> Int? {
        guard !query.isEmpty else { return nil }

        var score = 0
        var queryIndex = query.startIndex
        var targetIndex = target.startIndex
        var previousMatchIndex: String.Index?

        while queryIndex < query.endIndex, targetIndex < target.endIndex {
            let queryChar = query[queryIndex]
            let targetChar = target[targetIndex]

            if queryChar == targetChar {
                score += 1

                // Bonus for consecutive matches.
                if let prevIdx = previousMatchIndex,
                    target.index(after: prevIdx) == targetIndex
                {
                    score += 5
                }

                // Bonus for matching at word boundaries.
                if targetIndex == target.startIndex {
                    score += 10
                } else {
                    let prevTargetIndex = target.index(before: targetIndex)
                    let prevChar = target[prevTargetIndex]
                    if prevChar == " " || prevChar == "." || prevChar == "-" || prevChar == "_" {
                        score += 8
                    }
                }

                // Bonus for matching uppercase in camelCase.
                if targetChar.isUppercase {
                    score += 3
                }

                previousMatchIndex = targetIndex
                queryIndex = query.index(after: queryIndex)
            }

            targetIndex = target.index(after: targetIndex)
        }

        // All query characters must be matched.
        guard queryIndex == query.endIndex else { return nil }

        // Bonus for shorter targets (more specific match).
        let lengthDifference = target.count - query.count
        score -= lengthDifference

        // Bonus for prefix match.
        if target.hasPrefix(query) {
            score += 15
        }

        return score
    }
}

// MARK: - SpotlightObserver

/// Helper class that observes NSMetadataQuery notifications on behalf of the SearchService actor.
private final class SpotlightObserver: NSObject, @unchecked Sendable {
    private let continuation: AsyncStream<[FileItem]>.Continuation

    init(continuation: AsyncStream<[FileItem]>.Continuation) {
        self.continuation = continuation
    }

    @objc func queryDidUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        let items = extractItems(from: query)
        if !items.isEmpty {
            continuation.yield(items)
        }
    }

    @objc func queryDidFinish(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else {
            continuation.finish()
            return
        }
        let items = extractItems(from: query)
        if !items.isEmpty {
            continuation.yield(items)
        }
        query.stop()
        continuation.finish()
    }

    private func extractItems(from query: NSMetadataQuery) -> [FileItem] {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var items: [FileItem] = []
        items.reserveCapacity(query.resultCount)

        for i in 0..<query.resultCount {
            guard let result = query.result(at: i) as? NSMetadataItem else { continue }

            guard let path = result.value(forAttribute: NSMetadataItemPathKey) as? String else {
                continue
            }

            let url = URL(fileURLWithPath: path)

            // Use FileItem's factory method for consistent metadata extraction.
            if let item = FileItem.create(from: url) {
                items.append(item)
            }
        }

        return items
    }
}
