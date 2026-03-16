import Foundation

/// Protocol for file system operations, enabling mock implementations for testing.
protocol FileSystemServiceProtocol: Actor {
    var iconStyle: IconStyle { get set }
    func setIconStyle(_ style: IconStyle)
    func contentsOfDirectory(
        at url: URL, sortedBy sortField: SortField, order: SortOrder, showHiddenFiles: Bool
    ) async throws -> [FileItem]
    func fileInfo(at url: URL) async throws -> FileItem
    func createDirectory(at url: URL, named name: String) async throws -> URL
    func moveItems(from sources: [URL], to destination: URL) async throws
    func copyItems(from sources: [URL], to destination: URL) async throws
    func trashItems(urls: [URL]) async throws -> [URL]
    func renameItem(at url: URL, to newName: String) async throws -> URL
    func exists(at url: URL) -> Bool
    func batchRename(urls: [URL], pattern: BatchRenamePattern) async throws -> [URL]
    func createAlias(for sourceURL: URL, at destinationDirectory: URL) throws -> URL
}
