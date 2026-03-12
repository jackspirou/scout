import AppKit
import Foundation

// MARK: - ClipboardManager

/// Manages file clipboard operations (cut, copy, paste) with system pasteboard integration
/// and clipboard history.
@MainActor final class ClipboardManager {
    // MARK: - Constants

    /// Custom pasteboard type for Scout's cut operation marker.
    static let scoutCutPasteboardType = NSPasteboard.PasteboardType("com.scout.cut-files")
    static let scoutCopyPasteboardType = NSPasteboard.PasteboardType("com.scout.copy-files")

    private static let maxHistoryCount = 10

    // MARK: - Properties

    // Safety: NSPasteboard is not Sendable but this let-constant is assigned once in init.
    private nonisolated(unsafe) let pasteboard: NSPasteboard
    private let fileSystemService: FileSystemService
    private var _currentContent: ClipboardContent?
    private var _history: [ClipboardContent] = []

    // MARK: - Init

    nonisolated init(
        pasteboard: NSPasteboard = .general,
        fileSystemService: FileSystemService = FileSystemService()
    ) {
        self.pasteboard = pasteboard
        self.fileSystemService = fileSystemService
    }

    // MARK: - Cut

    /// Marks files for cutting. On paste, files will be moved.
    func cut(urls: [URL]) {
        guard !urls.isEmpty else { return }

        let content = ClipboardContent(urls: urls, operation: .cut)

        _currentContent = content
        addToHistory(content)

        writeToPasteboard(urls: urls, operation: .cut)
    }

    // MARK: - Copy

    /// Marks files for copying. On paste, files will be duplicated.
    func copy(urls: [URL]) {
        guard !urls.isEmpty else { return }

        let content = ClipboardContent(urls: urls, operation: .copy)

        _currentContent = content
        addToHistory(content)

        writeToPasteboard(urls: urls, operation: .copy)
    }

    // MARK: - Paste

    /// Pastes clipboard content to the specified destination.
    /// For cut operations, files are moved. For copy operations, files are duplicated.
    func paste(to destination: URL) async throws {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ClipboardError.pasteDestinationNotFound(destination)
        }

        let content: ClipboardContent

        // Try to read from our internal state first, then fall back to pasteboard.
        if let current = _currentContent {
            content = current
        } else if let pasteboardContent = readFromPasteboard() {
            content = pasteboardContent
        } else {
            throw ClipboardError.nothingToPaste
        }

        do {
            switch content.operation {
            case .cut:
                try await fileSystemService.moveItems(from: content.urls, to: destination)
                // After a cut+paste, clear the clipboard since files have been moved.
                _currentContent = nil
                clearPasteboard()

            case .copy:
                try await fileSystemService.copyItems(from: content.urls, to: destination)
            }
        } catch {
            throw ClipboardError.pasteFailed(error.localizedDescription)
        }
    }

    // MARK: - Query

    /// Returns whether there is content available to paste.
    func canPaste() -> Bool {
        if _currentContent != nil { return true }

        // Check system pasteboard for file URLs.
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: fileFilterOptions())
    }

    /// Returns the current clipboard content, if any.
    func currentContent() -> ClipboardContent? {
        if let content = _currentContent {
            return content
        }

        return readFromPasteboard()
    }

    /// Returns the clipboard history (last 10 operations).
    func clipboardHistory() -> [ClipboardContent] {
        return _history
    }

    // MARK: - Clear

    /// Clears the current clipboard content and the system pasteboard.
    func clear() {
        _currentContent = nil

        clearPasteboard()
    }

    // MARK: - Private Helpers

    private func writeToPasteboard(urls: [URL], operation: ClipboardOperation) {
        pasteboard.clearContents()

        // Write file URLs so other apps can receive them.
        let nsURLs = urls.map { $0 as NSURL }
        pasteboard.writeObjects(nsURLs)

        // Write our custom type to indicate cut vs copy.
        let markerType: NSPasteboard.PasteboardType =
            operation == .cut
                ? Self.scoutCutPasteboardType
                : Self.scoutCopyPasteboardType

        pasteboard.setString(operation.rawValue, forType: markerType)
    }

    private func readFromPasteboard() -> ClipboardContent? {
        guard
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: fileFilterOptions()
            ) as? [URL],
            !urls.isEmpty
        else {
            return nil
        }

        // Determine operation from our custom pasteboard types.
        let operation: ClipboardOperation
        if pasteboard.string(forType: Self.scoutCutPasteboardType) != nil {
            operation = .cut
        } else {
            operation = .copy
        }

        return ClipboardContent(urls: urls, operation: operation)
    }

    private func clearPasteboard() {
        pasteboard.clearContents()
    }

    private func addToHistory(_ content: ClipboardContent) {
        _history.insert(content, at: 0)
        if _history.count > Self.maxHistoryCount {
            _history.removeLast(_history.count - Self.maxHistoryCount)
        }
    }

    private func fileFilterOptions() -> [NSPasteboard.ReadingOptionKey: Any] {
        [
            .urlReadingFileURLsOnly: true,
        ]
    }
}
