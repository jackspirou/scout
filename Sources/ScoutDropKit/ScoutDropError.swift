import Foundation

// MARK: - ScoutDropError

/// Errors that can occur during ScoutDrop file transfers.
/// This is a standalone copy for the ScoutDropKit library target, kept in sync
/// with the definition at the top of ScoutDropService.swift.
enum ScoutDropError: LocalizedError {
    case connectionFailed(String)
    case transferDeclined
    case transferTimeout
    case invalidMessage
    case connectionClosed
    case writeFailed(String)
    case checksumMismatch(String)
    case identityKeyMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .connectionFailed(msg): return "Connection failed: \(msg)"
        case .transferDeclined: return "Transfer was declined"
        case .transferTimeout: return "Transfer timed out"
        case .invalidMessage: return "Received invalid message"
        case .connectionClosed: return "Connection closed unexpectedly"
        case let .writeFailed(msg): return "Failed to write file: \(msg)"
        case let .checksumMismatch(path): return "Checksum mismatch for \(path)"
        case let .identityKeyMismatch(name): return "Identity changed for \(name). The peer's cryptographic identity does not match the previously trusted key."
        }
    }
}
