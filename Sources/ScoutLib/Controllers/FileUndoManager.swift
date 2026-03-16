import AppKit
import Foundation

/// Centralized undo manager for file operations.
/// Registers inverse operations so that Cmd+Z undoes file moves, trashes, renames,
/// new folder creation, duplicates, and alias creation.
@MainActor
final class FileUndoManager {
    // MARK: - Singleton

    static let shared = FileUndoManager()

    // MARK: - Properties

    /// The underlying `NSUndoManager` exposed for responder chain integration.
    let undoManager = UndoManager()

    /// File system service used to perform inverse operations.
    private let fileSystemService = FileSystemService.shared

    // MARK: - Init

    private init() {}

    // MARK: - Record Move

    /// Records a move so that undo moves items back to their original locations.
    func recordMove(from sources: [URL], to destination: URL, resultingURLs: [URL]) {
        undoManager.registerUndo(withTarget: self) { target in
            Task {
                do {
                    try await target.fileSystemService.moveItems(
                        from: resultingURLs,
                        to: sources[0].deletingLastPathComponent()
                    )
                } catch {
                    NSLog("[FileUndoManager] Undo move failed: %@", error.localizedDescription)
                }
            }
        }
        undoManager.setActionName("Move")
    }

    // MARK: - Record Trash

    /// Records a trash operation so that undo restores items from the trash.
    func recordTrash(originalURLs: [URL], trashedURLs: [URL]) {
        let pairs = zip(originalURLs, trashedURLs).map { ($0, $1) }
        undoManager.registerUndo(withTarget: self) { _ in
            Task {
                let fm = FileManager.default
                for (originalURL, trashedURL) in pairs {
                    do {
                        try fm.moveItem(at: trashedURL, to: originalURL)
                    } catch {
                        NSLog("[FileUndoManager] Undo trash failed for %@: %@",
                              originalURL.path, error.localizedDescription)
                    }
                }
            }
        }
        undoManager.setActionName("Move to Trash")
    }

    // MARK: - Record Rename

    /// Records a rename so that undo renames back to the original name.
    func recordRename(oldURL: URL, newURL: URL) {
        undoManager.registerUndo(withTarget: self) { target in
            Task {
                do {
                    _ = try await target.fileSystemService.renameItem(
                        at: newURL,
                        to: oldURL.lastPathComponent
                    )
                } catch {
                    NSLog("[FileUndoManager] Undo rename failed: %@", error.localizedDescription)
                }
            }
        }
        undoManager.setActionName("Rename")
    }

    // MARK: - Trashable Creation (shared helper)

    /// Shared helper for operations that create a new item (new folder, duplicate, alias).
    /// Undo trashes the created item; redo re-creates it.
    func recordTrashableCreation(url: URL, actionName: String, redo: @escaping () -> Void) {
        undoManager.registerUndo(withTarget: self) { target in
            Task {
                do {
                    _ = try await target.fileSystemService.trashItems(urls: [url])
                } catch {
                    NSLog("[FileUndoManager] Undo %@ failed: %@",
                          actionName, error.localizedDescription)
                }
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Convenience Methods

    /// Records creation of a new folder.
    func recordNewFolder(url: URL) {
        recordTrashableCreation(url: url, actionName: "New Folder") {}
    }

    /// Records a duplicate operation.
    func recordDuplicate(duplicateURL: URL) {
        recordTrashableCreation(url: duplicateURL, actionName: "Duplicate") {}
    }

    /// Records creation of an alias.
    func recordAlias(url: URL) {
        recordTrashableCreation(url: url, actionName: "Make Alias") {}
    }
}
