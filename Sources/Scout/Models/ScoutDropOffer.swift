import Foundation

// MARK: - ScoutDropOffer

/// Incoming transfer offer for the accept/decline UI.
struct ScoutDropOffer: Identifiable {
    let id: UUID          // transferID
    let senderName: String
    let files: [ScoutDropFileEntry]
    let totalSize: Int64
    let verificationCode: String
    let senderDeviceID: String
    let peerPublicKeyHash: String?

    var fileCount: Int { files.filter { !$0.isDirectory }.count }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}
