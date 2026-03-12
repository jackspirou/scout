import Foundation

// MARK: - ClipboardOperation

enum ClipboardOperation: String, Codable {
    case cut
    case copy
}

// MARK: - ClipboardContent

struct ClipboardContent: Identifiable {
    let id: UUID
    let urls: [URL]
    let operation: ClipboardOperation
    let timestamp: Date

    init(
        id: UUID = UUID(),
        urls: [URL],
        operation: ClipboardOperation,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.urls = urls
        self.operation = operation
        self.timestamp = timestamp
    }
}

// MARK: - ClipboardError

enum ClipboardError: LocalizedError {
    case nothingToPaste
    case pasteDestinationNotFound(URL)
    case pasteFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingToPaste:
            return "Nothing to paste"
        case let .pasteDestinationNotFound(url):
            return "Paste destination not found: \(url.path)"
        case let .pasteFailed(reason):
            return "Paste failed: \(reason)"
        }
    }
}
