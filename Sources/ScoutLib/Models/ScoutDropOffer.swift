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

    /// Verification code formatted with a space for readability (e.g. "123 456").
    var formattedVerificationCode: String {
        Self.formatCode(verificationCode)
    }

    /// Formats a 6-digit code as "XXX XXX" for easier visual comparison.
    static func formatCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let idx = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<idx]) \(code[idx...])"
    }
}
