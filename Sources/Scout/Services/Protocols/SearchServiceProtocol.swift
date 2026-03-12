import Foundation

/// Protocol for search operations, enabling mock implementations for testing.
protocol SearchServiceProtocol: Actor {
    func search(query: String, scope: SearchScope, filters: [SearchFilter]) -> AsyncStream<
        [FileItem]
    >
    func fuzzyMatch(query: String, in directory: URL) async -> [FileItem]
    func cancelActiveSearch()
}
