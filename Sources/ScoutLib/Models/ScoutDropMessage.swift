import Foundation

// MARK: - ScoutDropFileEntry

struct ScoutDropFileEntry: Codable {
    let relativePath: String
    let size: Int64
    let isDirectory: Bool
    var posixPermissions: Int?
    var isSymlink: Bool = false
    var symlinkTarget: String?
}

// MARK: - ScoutDropOfferMetadata

/// Metadata for an offer message.
struct ScoutDropOfferMetadata: Codable {
    let senderName: String
    let transferID: UUID
    let files: [ScoutDropFileEntry]
    let totalSize: Int64
    let senderDeviceID: String
}

// MARK: - ScoutDropAcceptMetadata

/// Metadata for an accept message, including resume offsets.
struct ScoutDropAcceptMetadata: Codable {
    let transferID: UUID
    /// For resume: maps fileIndex -> number of bytes already received.
    /// Empty dict means start from beginning for all files.
    var resumeOffsets: [Int: Int64] = [:]
}

// MARK: - ScoutDropControlMetadata

/// Simple metadata for decline/complete/error messages.
struct ScoutDropControlMetadata: Codable {
    let transferID: UUID
    var errorMessage: String?
}

// MARK: - ScoutDropFileErrorMetadata

/// Per-file error sent on the control stream when a single file fails during receive.
struct ScoutDropFileErrorMetadata: Codable {
    let transferID: UUID
    let fileIndex: Int
    let errorMessage: String
}
