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
actor SearchService: SearchServiceProtocol {
    private var activeQuery: NSMetadataQuery?
    private var activeObserver: SpotlightObserver?
    private var debounceTask: Task<Void, Never>?
    private nonisolated let debounceInterval: Duration
    private let fileSystemService: FileSystemService

    init(
        debounceInterval: Duration = .milliseconds(200),
        fileSystemService: FileSystemService = .shared
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

            continuation.onTermination = { [weak self] _ in
                taskHandle.cancel()
                Task { [weak self] in
                    await self?.cancelActiveSearch()
                }
            }
        }
    }

    // MARK: - Fuzzy Match

    /// Performs fuzzy filename matching within a directory and returns scored results.
    func fuzzyMatch(query: String, in directory: URL) async -> [FileItem] {
        guard !query.isEmpty else { return [] }

        let items: [FileItem]
        do {
            items = try await fileSystemService.contentsOfDirectory(at: directory, showHiddenFiles: true)
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
        // Build the predicate and scope values here, then create and configure the
        // NSMetadataQuery entirely on the main thread. NSMetadataQuery requires ALL
        // interactions (creation, configuration, start) on the main run loop thread.
        // nonisolated(unsafe) because NSPredicate doesn't conform to Sendable,
        // but the predicate is fully constructed here and only read on the main thread.
        nonisolated(unsafe) let predicate = buildPredicate(query: queryString, filters: filters)

        let searchScopes: [Any]
        switch scope {
        case let .currentFolder(url):
            searchScopes = [url]
        case let .subfolder(url):
            searchScopes = [url]
        case .fullDisk:
            searchScopes = [NSMetadataQueryLocalComputerScope]
        }

        let observer = SpotlightObserver(continuation: continuation)
        activeObserver = observer

        // Capture self for storing the query reference back in the actor.
        let weakSelf = self

        DispatchQueue.main.async {
            let metadataQuery = NSMetadataQuery()
            metadataQuery.predicate = predicate
            metadataQuery.sortDescriptors = [
                NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true),
            ]
            metadataQuery.searchScopes = searchScopes
            metadataQuery.notificationBatchingInterval = 0.15

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

            Task {
                await weakSelf.storeActiveQuery(metadataQuery)
            }

            metadataQuery.start()
        }
    }

    /// Stores the active query reference (called from main thread via Task).
    private func storeActiveQuery(_ query: NSMetadataQuery) {
        activeQuery = query
    }

    private func buildPredicate(query: String, filters: [SearchFilter]) -> NSPredicate {
        // Use NSPredicate(fromMetadataQueryString:) which parses Spotlight's native
        // query syntax directly. This bypasses the NSPredicate-to-Spotlight translation
        // layer entirely, avoiding crashes in generateMetadataDescription.
        var queryParts: [String] = []

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let hasWildcards = GlobPattern.hasWildcards(trimmed)

        if trimmed.isEmpty {
            queryParts.append("kMDItemFSName == '*'")
        } else {
            // Escape single quotes in user input.
            let escaped = trimmed.replacingOccurrences(of: "'", with: "\\'")
            if hasWildcards {
                queryParts.append("kMDItemFSName == '\(escaped)'cd")
            } else {
                queryParts.append("kMDItemFSName == '*\(escaped)*'cd")
            }
        }

        for filter in filters {
            switch filter {
            case let .kind(kind):
                let escaped = kind.replacingOccurrences(of: "'", with: "\\'")
                queryParts.append("kMDItemContentType == '\(escaped)'")

            case let .sizeGreaterThan(size):
                queryParts.append("kMDItemFSSize > \(size)")

            case let .sizeLessThan(size):
                queryParts.append("kMDItemFSSize < \(size)")

            case let .modifiedAfter(date):
                let timestamp = date.timeIntervalSince1970
                queryParts.append("kMDItemFSContentChangeDate > $time.iso(\(timestamp))")

            case let .modifiedBefore(date):
                let timestamp = date.timeIntervalSince1970
                queryParts.append("kMDItemFSContentChangeDate < $time.iso(\(timestamp))")

            case let .hasTag(tag):
                let escaped = tag.replacingOccurrences(of: "'", with: "\\'")
                queryParts.append("kMDItemUserTags == '\(escaped)'cd")
            }
        }

        let queryString = queryParts.joined(separator: " && ")

        if let predicate = NSPredicate(fromMetadataQueryString: queryString) {
            return predicate
        }

        // Fallback: if the native query string parsing fails, use a simple NSPredicate.
        // This should not happen with well-formed queries, but prevents a crash.
        NSLog("[SearchService] Failed to parse metadata query string: %@", queryString)
        return NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, "*")
    }
}

// MARK: - SpotlightObserver

/// Helper class that observes NSMetadataQuery notifications on behalf of the SearchService actor.
private final class SpotlightObserver: NSObject, @unchecked Sendable {
    private let continuation: AsyncStream<[FileItem]>.Continuation

    init(continuation: AsyncStream<[FileItem]>.Continuation) {
        self.continuation = continuation
    }

    /// Removes all notification observations for the given query.
    func removeObservers(for query: NSMetadataQuery) {
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
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
        removeObservers(for: query)
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
