import Foundation
import Observation

// MARK: - TransferType

/// The kind of file transfer operation.
enum TransferType: String, Codable, Sendable {
    case copy
    case move
    case trash
}

// MARK: - TransferStatus

/// Lifecycle state of a transfer operation.
enum TransferStatus: String, Sendable {
    case pending
    case inProgress
    case paused
    case completed
    case failed
    case cancelled

    /// Backward-compatible aliases for code using the older naming.
    static let queued = TransferStatus.pending
    static let running = TransferStatus.inProgress
}

// MARK: - ConflictResolution

/// Strategy for resolving naming conflicts at the destination.
enum ConflictResolution: Sendable {
    case replace
    case skip
    case keepBoth
    case rename
    case replaceAll
    case skipAll
    case cancel
}

// MARK: - TransferOperation

/// Observable model tracking a file copy or move operation.
@Observable
final class TransferOperation: Identifiable, @unchecked Sendable {

    // MARK: - Identity

    nonisolated let id: UUID

    // MARK: - Configuration

    nonisolated let sourceURLs: [URL]
    nonisolated let destinationURL: URL
    nonisolated let type: TransferType
    nonisolated let createdAt: Date

    // MARK: - Progress Tracking

    @ObservationIgnored
    let progress: Progress

    // MARK: - State

    @MainActor var status: TransferStatus
    @MainActor var currentFile: String
    @MainActor var bytesTransferred: Int64
    @MainActor var totalBytes: Int64
    @MainActor var speed: Double
    @MainActor var error: String?

    /// Backward-compatible alias for code using `sources`.
    var sources: [URL] { sourceURLs }

    /// Backward-compatible alias for code using `destination`.
    var destination: URL { destinationURL }

    // MARK: - Initializer

    @MainActor
    init(
        id: UUID = UUID(),
        sourceURLs: [URL],
        destinationURL: URL,
        type: TransferType,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceURLs = sourceURLs
        self.destinationURL = destinationURL
        self.type = type
        self.createdAt = createdAt
        self.progress = Progress(totalUnitCount: 0)
        self.status = .pending
        self.currentFile = ""
        self.bytesTransferred = 0
        self.totalBytes = 0
        self.speed = 0
        self.error = nil
    }

    /// Backward-compatible initializer matching old `sources` / `destination` parameter names.
    @MainActor
    convenience init(
        id: UUID = UUID(),
        sources: [URL],
        destination: URL,
        type: TransferType,
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            sourceURLs: sources,
            destinationURL: destination,
            type: type,
            createdAt: createdAt
        )
    }

    // MARK: - Computed Properties

    /// Estimated seconds remaining based on current transfer speed. Returns `nil` when speed is zero.
    @MainActor
    var estimatedTimeRemaining: TimeInterval? {
        guard speed > 0 else { return nil }
        let remainingBytes = Double(totalBytes - bytesTransferred)
        return remainingBytes / speed
    }

    /// Human-readable transfer speed (e.g., "12.4 MB/s").
    @MainActor
    var formattedSpeed: String {
        guard speed > 0 else { return "0 B/s" }
        return TransferOperation.byteCountFormatter.string(fromByteCount: Int64(speed)) + "/s"
    }

    /// Human-readable progress string (e.g., "45.2 MB of 1.3 GB").
    @MainActor
    var formattedProgress: String {
        let formatter = TransferOperation.byteCountFormatter
        let transferred = formatter.string(fromByteCount: bytesTransferred)
        let total = formatter.string(fromByteCount: totalBytes)
        return "\(transferred) of \(total)"
    }

    // MARK: - Private

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter
    }()
}
