import AppKit
import Foundation

// MARK: - SearchScope

enum SearchScope {
    case currentFolder(URL)
    case subfolder(URL)
    case fullDisk
}

// MARK: - SearchFilter

enum SearchFilter {
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
        case let .queryFailed(reason):
            return "Search failed: \(reason)"
        }
    }
}

// MARK: - SearchService

/// Actor-based service for file search using Spotlight and custom fuzzy matching.
actor SearchService {
    private var activeQuery: NSMetadataQuery?
    private var activeObserver: SpotlightObserver?
    private var debounceTask: Task<Void, Never>?
    private nonisolated let debounceInterval: Duration
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
                try? await Task.sleep(for: self.debounceInterval)

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
    func fuzzyMatch(query: String, in directory: URL, iconStyle: IconStyle = .system) async -> [FileItem] {
        guard !query.isEmpty else { return [] }

        let items: [FileItem]
        do {
            items = try await fileSystemService.contentsOfDirectory(at: directory, iconStyle: iconStyle)
        } catch {
            return []
        }

        var scoredItems: [(FileItem, Int)] = []

        for item in items {
            if let score = item.name.fuzzyMatchScore(query: query) {
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
            if let observer = activeObserver {
                NotificationCenter.default.removeObserver(observer, name: nil, object: query)
                activeObserver = nil
            }
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
            NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true),
        ]

        switch scope {
        case let .currentFolder(url):
            metadataQuery.searchScopes = [url]
        case let .subfolder(url):
            metadataQuery.searchScopes = [url]
        case .fullDisk:
            metadataQuery.searchScopes = [
                NSMetadataQueryLocalComputerScope,
            ]
        }

        // Batch results for performance.
        metadataQuery.notificationBatchingInterval = 0.15

        let observer = SpotlightObserver(continuation: continuation)
        activeObserver = observer

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

        activeQuery = metadataQuery

        // NSMetadataQuery must run on the main run loop.
        // Safety: metadataQuery is created here and only used on the main thread.
        nonisolated(unsafe) let query = metadataQuery
        DispatchQueue.main.async {
            query.start()
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
            case let .kind(kind):
                subpredicates.append(
                    NSPredicate(
                        format: "%K == %@",
                        NSMetadataItemContentTypeKey,
                        kind
                    )
                )

            case let .sizeGreaterThan(size):
                subpredicates.append(
                    NSPredicate(
                        format: "%K > %lld",
                        NSMetadataItemFSSizeKey,
                        size
                    )
                )

            case let .sizeLessThan(size):
                subpredicates.append(
                    NSPredicate(
                        format: "%K < %lld",
                        NSMetadataItemFSSizeKey,
                        size
                    )
                )

            case let .modifiedAfter(date):
                subpredicates.append(
                    NSPredicate(
                        format: "%K > %@",
                        NSMetadataItemFSContentChangeDateKey,
                        date as NSDate
                    )
                )

            case let .modifiedBefore(date):
                subpredicates.append(
                    NSPredicate(
                        format: "%K < %@",
                        NSMetadataItemFSContentChangeDateKey,
                        date as NSDate
                    )
                )

            case let .hasTag(tag):
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

        for i in 0 ..< query.resultCount {
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
