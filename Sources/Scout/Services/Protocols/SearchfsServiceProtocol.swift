import Foundation

// MARK: - SearchfsServiceProtocol

/// Protocol for the searchfs-based catalog search service.
/// Uses the searchfs() syscall to read the APFS/HFS+ catalog B-tree directly,
/// providing fast, complete filename search with no Spotlight index dependency.
///
/// Targets external/non-Spotlight-indexed volumes where Spotlight has no coverage.
protocol SearchfsServiceProtocol: Actor {
    /// Search non-Spotlight-indexed volumes that support searchfs() for files matching the query.
    func searchNonIndexedVolumes(query: String, maxResults: UInt32) -> AsyncStream<[FileItem]>

    /// Search a single volume for files matching the query.
    func search(query: String, volumePath: String, maxResults: UInt32) -> AsyncStream<[FileItem]>

    /// Cancel any active search operation.
    func cancelActiveSearch()
}
