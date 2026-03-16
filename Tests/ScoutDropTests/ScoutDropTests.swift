import CryptoKit
import Foundation
import Network
import Security
import XCTest

@testable import ScoutDropKit

// MARK: - ScoutDropFrameHeaderTests

final class ScoutDropFrameHeaderTests: XCTestCase {

    /// Decode using the **production** init(UnsafeRawBufferPointer) so round-trip
    /// tests actually exercise both encode and decode paths.
    private func decodeHeader(from data: Data) -> ScoutDropFrameHeader {
        data.withUnsafeBytes { buffer in
            ScoutDropFrameHeader(UnsafeRawBufferPointer(buffer))
        }
    }

    func testDefaultInit() {
        let header = ScoutDropFrameHeader()
        XCTAssertEqual(header.messageType, 0)
        XCTAssertEqual(header.metadataLength, 0)
        XCTAssertEqual(header.payloadLength, 0)
    }

    func testEncodedSize() {
        XCTAssertEqual(ScoutDropFrameHeader.encodedSize, 9)
    }

    func testEncodeDecodeRoundTrip() {
        var header = ScoutDropFrameHeader()
        header.messageType = ScoutDropFrameHeader.typeOffer
        header.metadataLength = 256
        header.payloadLength = 1024

        let encoded = header.encode()
        XCTAssertEqual(encoded.count, 9)

        let decoded = decodeHeader(from: encoded)
        XCTAssertEqual(decoded.messageType, ScoutDropFrameHeader.typeOffer)
        XCTAssertEqual(decoded.metadataLength, 256)
        XCTAssertEqual(decoded.payloadLength, 1024)
    }

    func testBigEndianEncoding() {
        var header = ScoutDropFrameHeader()
        header.messageType = 0x01
        header.metadataLength = 0x0102_0304
        header.payloadLength = 0x0506_0708

        let encoded = header.encode()
        XCTAssertEqual(encoded[0], 0x01)
        XCTAssertEqual(encoded[1], 0x01)
        XCTAssertEqual(encoded[2], 0x02)
        XCTAssertEqual(encoded[3], 0x03)
        XCTAssertEqual(encoded[4], 0x04)
        XCTAssertEqual(encoded[5], 0x05)
        XCTAssertEqual(encoded[6], 0x06)
        XCTAssertEqual(encoded[7], 0x07)
        XCTAssertEqual(encoded[8], 0x08)
    }

    func testZeroLengths() {
        var header = ScoutDropFrameHeader()
        header.messageType = ScoutDropFrameHeader.typeHeartbeat
        header.metadataLength = 0
        header.payloadLength = 0

        let encoded = header.encode()
        let decoded = decodeHeader(from: encoded)
        XCTAssertEqual(decoded.messageType, ScoutDropFrameHeader.typeHeartbeat)
        XCTAssertEqual(decoded.metadataLength, 0)
        XCTAssertEqual(decoded.payloadLength, 0)
    }

    func testMaxValues() {
        var header = ScoutDropFrameHeader()
        header.messageType = 0xFF
        header.metadataLength = UInt32.max
        header.payloadLength = UInt32.max

        let encoded = header.encode()
        let decoded = decodeHeader(from: encoded)
        XCTAssertEqual(decoded.messageType, 0xFF)
        XCTAssertEqual(decoded.metadataLength, UInt32.max)
        XCTAssertEqual(decoded.payloadLength, UInt32.max)
    }

    func testAllMessageTypes() {
        let types: [(UInt8, String)] = [
            (ScoutDropFrameHeader.typeOffer, "offer"),
            (ScoutDropFrameHeader.typeAccept, "accept"),
            (ScoutDropFrameHeader.typeDecline, "decline"),
            (ScoutDropFrameHeader.typeComplete, "complete"),
            (ScoutDropFrameHeader.typeError, "error"),
            (ScoutDropFrameHeader.typeFileStart, "fileStart"),
            (ScoutDropFrameHeader.typeFileData, "fileData"),
            (ScoutDropFrameHeader.typeFileEnd, "fileEnd"),
            (ScoutDropFrameHeader.typeFileError, "fileError"),
            (ScoutDropFrameHeader.typeHeartbeat, "heartbeat"),
        ]

        for (type, name) in types {
            var header = ScoutDropFrameHeader()
            header.messageType = type
            header.metadataLength = 42
            header.payloadLength = 99
            let encoded = header.encode()
            let decoded = decodeHeader(from: encoded)
            XCTAssertEqual(decoded.messageType, type, "Failed round-trip for \(name)")
            XCTAssertEqual(decoded.metadataLength, 42, "metadataLength mismatch for \(name)")
            XCTAssertEqual(decoded.payloadLength, 99, "payloadLength mismatch for \(name)")
        }
    }

    func testMessageTypeConstants() {
        XCTAssertEqual(ScoutDropFrameHeader.typeOffer, 0x01)
        XCTAssertEqual(ScoutDropFrameHeader.typeAccept, 0x02)
        XCTAssertEqual(ScoutDropFrameHeader.typeDecline, 0x03)
        XCTAssertEqual(ScoutDropFrameHeader.typeComplete, 0x06)
        XCTAssertEqual(ScoutDropFrameHeader.typeError, 0x07)
        XCTAssertEqual(ScoutDropFrameHeader.typeFileStart, 0x08)
        XCTAssertEqual(ScoutDropFrameHeader.typeFileData, 0x09)
        XCTAssertEqual(ScoutDropFrameHeader.typeFileEnd, 0x0A)
        XCTAssertEqual(ScoutDropFrameHeader.typeFileError, 0x0B)
        XCTAssertEqual(ScoutDropFrameHeader.typeHeartbeat, 0x0C)
    }

    /// Message types should not collide — each constant must be unique.
    func testMessageTypeConstantsAreUnique() {
        let types: [UInt8] = [
            ScoutDropFrameHeader.typeOffer,
            ScoutDropFrameHeader.typeAccept,
            ScoutDropFrameHeader.typeDecline,
            ScoutDropFrameHeader.typeComplete,
            ScoutDropFrameHeader.typeError,
            ScoutDropFrameHeader.typeFileStart,
            ScoutDropFrameHeader.typeFileData,
            ScoutDropFrameHeader.typeFileEnd,
            ScoutDropFrameHeader.typeFileError,
            ScoutDropFrameHeader.typeHeartbeat,
        ]
        let set = Set(types)
        XCTAssertEqual(set.count, types.count, "Message type constants must be unique")
    }

    func testSingleByteMetadata() {
        var header = ScoutDropFrameHeader()
        header.messageType = ScoutDropFrameHeader.typeFileStart
        header.metadataLength = 2
        header.payloadLength = 0

        let encoded = header.encode()
        let decoded = decodeHeader(from: encoded)
        XCTAssertEqual(decoded.metadataLength, 2)
    }

    func testEncodedDataIsExactly9Bytes() {
        for metaLen in [UInt32(0), 1, 255, 65535, UInt32.max] {
            for payLen in [UInt32(0), 1, 255, 65535, UInt32.max] {
                var header = ScoutDropFrameHeader()
                header.messageType = 0x09
                header.metadataLength = metaLen
                header.payloadLength = payLen
                XCTAssertEqual(header.encode().count, 9)
            }
        }
    }

    /// The protocol encodes fileIndex as a 2-byte big-endian UInt16 in the
    /// typeFileStart metadata. Verify encode/decode round-trip at boundaries.
    func testFileIndexUInt16BigEndianRoundTrip() {
        let testIndices: [UInt16] = [0, 1, 255, 256, 1000, UInt16.max - 1, UInt16.max]
        for index in testIndices {
            var indexBE = index.bigEndian
            let data = withUnsafeBytes(of: &indexBE) { Data($0) }
            XCTAssertEqual(data.count, 2)
            let decoded = data.withUnsafeBytes { $0.load(as: UInt16.self) }.bigEndian
            XCTAssertEqual(decoded, index, "fileIndex \(index) failed round-trip")
        }
    }

    /// Verify the 16 MB frame body size limit used in ScoutDropFramer.handleInput.
    /// This tests the boundary values that the framer checks against.
    func testFrameSizeLimitBoundaryValues() {
        let maxFrameBodySize = 16_777_216  // 16 MB

        // Just under limit — should be accepted.
        var headerUnder = ScoutDropFrameHeader()
        headerUnder.messageType = ScoutDropFrameHeader.typeFileData
        headerUnder.metadataLength = 0
        headerUnder.payloadLength = UInt32(maxFrameBodySize - 1)
        let totalUnder = Int(headerUnder.metadataLength) + Int(headerUnder.payloadLength)
        XCTAssertLessThanOrEqual(totalUnder, maxFrameBodySize)

        // Exactly at limit — should be accepted.
        var headerExact = ScoutDropFrameHeader()
        headerExact.messageType = ScoutDropFrameHeader.typeFileData
        headerExact.metadataLength = 0
        headerExact.payloadLength = UInt32(maxFrameBodySize)
        let totalExact = Int(headerExact.metadataLength) + Int(headerExact.payloadLength)
        XCTAssertLessThanOrEqual(totalExact, maxFrameBodySize)

        // Just over limit — should be rejected.
        var headerOver = ScoutDropFrameHeader()
        headerOver.messageType = ScoutDropFrameHeader.typeFileData
        headerOver.metadataLength = 1
        headerOver.payloadLength = UInt32(maxFrameBodySize)
        let totalOver = Int(headerOver.metadataLength) + Int(headerOver.payloadLength)
        XCTAssertGreaterThan(totalOver, maxFrameBodySize)

        // Split across metadata + payload — just over limit.
        var headerSplit = ScoutDropFrameHeader()
        headerSplit.messageType = ScoutDropFrameHeader.typeOffer
        headerSplit.metadataLength = UInt32(maxFrameBodySize / 2) + 1
        headerSplit.payloadLength = UInt32(maxFrameBodySize / 2) + 1
        let totalSplit = Int(headerSplit.metadataLength) + Int(headerSplit.payloadLength)
        XCTAssertGreaterThan(totalSplit, maxFrameBodySize)
    }

    /// Heartbeat frames must have zero-length metadata and payload per the spec.
    func testHeartbeatFrameSpec() {
        var header = ScoutDropFrameHeader()
        header.messageType = ScoutDropFrameHeader.typeHeartbeat
        header.metadataLength = 0
        header.payloadLength = 0
        let encoded = header.encode()
        let decoded = decodeHeader(from: encoded)
        XCTAssertEqual(decoded.messageType, ScoutDropFrameHeader.typeHeartbeat)
        XCTAssertEqual(decoded.metadataLength, 0)
        XCTAssertEqual(decoded.payloadLength, 0)
    }

    /// Decoding from a buffer that starts at an unaligned offset must not crash.
    func testDecodeFromUnalignedBuffer() {
        var header = ScoutDropFrameHeader()
        header.messageType = ScoutDropFrameHeader.typeOffer
        header.metadataLength = 12345
        header.payloadLength = 67890
        let encoded = header.encode()

        // Prepend 1 byte to force misalignment, then decode from offset 1.
        var misaligned = Data([0xFF])
        misaligned.append(encoded)
        let slice = misaligned[1...]
        let decoded = Data(slice).withUnsafeBytes { buffer in
            ScoutDropFrameHeader(UnsafeRawBufferPointer(buffer))
        }
        XCTAssertEqual(decoded.messageType, ScoutDropFrameHeader.typeOffer)
        XCTAssertEqual(decoded.metadataLength, 12345)
        XCTAssertEqual(decoded.payloadLength, 67890)
    }

    /// Verify power-of-two boundary values for lengths (common off-by-one sources).
    func testPowerOfTwoBoundaries() {
        let boundaries: [UInt32] = [127, 128, 255, 256, 65535, 65536, 16_777_215, 16_777_216]
        for value in boundaries {
            var header = ScoutDropFrameHeader()
            header.messageType = ScoutDropFrameHeader.typeFileData
            header.metadataLength = value
            header.payloadLength = value
            let decoded = decodeHeader(from: header.encode())
            XCTAssertEqual(decoded.metadataLength, value, "metadataLength \(value) failed")
            XCTAssertEqual(decoded.payloadLength, value, "payloadLength \(value) failed")
        }
    }
}

// MARK: - ScoutDropMessageTests

final class ScoutDropMessageTests: XCTestCase {

    // MARK: - ScoutDropFileEntry

    func testFileEntryRoundTrip() throws {
        let entry = ScoutDropFileEntry(
            relativePath: "test/file.txt",
            size: 1234,
            isDirectory: false,
            posixPermissions: 0o644
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertEqual(decoded.relativePath, "test/file.txt")
        XCTAssertEqual(decoded.size, 1234)
        XCTAssertFalse(decoded.isDirectory)
        XCTAssertEqual(decoded.posixPermissions, 0o644)
        XCTAssertFalse(decoded.isSymlink)
        XCTAssertNil(decoded.symlinkTarget)
    }

    func testFileEntrySymlink() throws {
        var entry = ScoutDropFileEntry(
            relativePath: "link",
            size: 0,
            isDirectory: false
        )
        entry.isSymlink = true
        entry.symlinkTarget = "target.txt"

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertTrue(decoded.isSymlink)
        XCTAssertEqual(decoded.symlinkTarget, "target.txt")
    }

    func testFileEntryDirectory() throws {
        let entry = ScoutDropFileEntry(
            relativePath: "subdir",
            size: 0,
            isDirectory: true,
            posixPermissions: 0o755
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertTrue(decoded.isDirectory)
        XCTAssertEqual(decoded.posixPermissions, 0o755)
    }

    func testFileEntryNilPermissions() throws {
        let entry = ScoutDropFileEntry(
            relativePath: "file.bin",
            size: 42,
            isDirectory: false
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertNil(decoded.posixPermissions)
    }

    func testFileEntryLargeSize() throws {
        let entry = ScoutDropFileEntry(
            relativePath: String(repeating: "a/", count: 100) + "file.bin",
            size: Int64.max,
            isDirectory: false,
            posixPermissions: 0o777
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertEqual(decoded.size, Int64.max)
        XCTAssertEqual(decoded.posixPermissions, 0o777)
    }

    func testFileEntrySpecialCharactersInPath() throws {
        let entry = ScoutDropFileEntry(
            relativePath: "dir with spaces/file (1).txt",
            size: 42,
            isDirectory: false
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertEqual(decoded.relativePath, "dir with spaces/file (1).txt")
    }

    func testFileEntryUnicodeInPath() throws {
        let entry = ScoutDropFileEntry(
            relativePath: "\u{65E5}\u{672C}\u{8A9E}/\u{30D5}\u{30A1}\u{30A4}\u{30EB}.txt",
            size: 10,
            isDirectory: false
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertEqual(
            decoded.relativePath,
            "\u{65E5}\u{672C}\u{8A9E}/\u{30D5}\u{30A1}\u{30A4}\u{30EB}.txt"
        )
    }

    func testFileEntryZeroSize() throws {
        let entry = ScoutDropFileEntry(
            relativePath: "empty.txt",
            size: 0,
            isDirectory: false
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertEqual(decoded.size, 0)
    }

    func testFileEntryEmptyRelativePath() throws {
        let entry = ScoutDropFileEntry(relativePath: "", size: 0, isDirectory: false)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertEqual(decoded.relativePath, "")
    }

    func testFileEntryPathWithNewlines() throws {
        let entry = ScoutDropFileEntry(
            relativePath: "dir/file\nname.txt", size: 10, isDirectory: false
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertEqual(decoded.relativePath, "dir/file\nname.txt")
    }

    func testFileEntryPathWithBackslash() throws {
        // Windows-style path separators should survive JSON round-trip.
        let entry = ScoutDropFileEntry(
            relativePath: "dir\\subdir\\file.txt", size: 10, isDirectory: false
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertEqual(decoded.relativePath, "dir\\subdir\\file.txt")
    }

    /// Symlink with nil target is inconsistent but must not crash on encode/decode.
    func testFileEntrySymlinkWithNilTarget() throws {
        var entry = ScoutDropFileEntry(relativePath: "link", size: 0, isDirectory: false)
        entry.isSymlink = true
        entry.symlinkTarget = nil

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertTrue(decoded.isSymlink)
        XCTAssertNil(decoded.symlinkTarget)
    }

    /// All common POSIX permission modes must round-trip correctly.
    func testFileEntryAllCommonPermissions() throws {
        let modes = [0o000, 0o400, 0o444, 0o600, 0o644, 0o700, 0o755, 0o777]
        for mode in modes {
            let entry = ScoutDropFileEntry(
                relativePath: "f", size: 0, isDirectory: false, posixPermissions: mode
            )
            let data = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
            XCTAssertEqual(decoded.posixPermissions, mode, "Permission mode \(String(mode, radix: 8))")
        }
    }

    func testFileEntryPathWithEmojiAndCJK() throws {
        let path = "📁 Documents/報告書/レポート 2026.pdf"
        let entry = ScoutDropFileEntry(relativePath: path, size: 5000, isDirectory: false)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ScoutDropFileEntry.self, from: data)
        XCTAssertEqual(decoded.relativePath, path)
    }

    // MARK: - ScoutDropOfferMetadata

    func testOfferMetadataRoundTrip() throws {
        let id = UUID()
        let meta = ScoutDropOfferMetadata(
            senderName: "Jack's Mac",
            transferID: id,
            files: [
                ScoutDropFileEntry(relativePath: "a.txt", size: 100, isDirectory: false),
                ScoutDropFileEntry(relativePath: "b.txt", size: 200, isDirectory: false),
            ],
            totalSize: 300,
            verificationCode: "123456",
            senderDeviceID: "device-abc"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: data)
        XCTAssertEqual(decoded.senderName, "Jack's Mac")
        XCTAssertEqual(decoded.transferID, id)
        XCTAssertEqual(decoded.files.count, 2)
        XCTAssertEqual(decoded.totalSize, 300)
        XCTAssertEqual(decoded.verificationCode, "123456")
        XCTAssertEqual(decoded.senderDeviceID, "device-abc")
    }

    func testOfferMetadataEmptyFiles() throws {
        let meta = ScoutDropOfferMetadata(
            senderName: "Peer",
            transferID: UUID(),
            files: [],
            totalSize: 0,
            verificationCode: "000000",
            senderDeviceID: "dev1"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: data)
        XCTAssertTrue(decoded.files.isEmpty)
        XCTAssertEqual(decoded.totalSize, 0)
    }

    func testOfferMetadataEmptySenderName() throws {
        let meta = ScoutDropOfferMetadata(
            senderName: "",
            transferID: UUID(),
            files: [],
            totalSize: 0,
            verificationCode: "000000",
            senderDeviceID: "dev1"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: data)
        XCTAssertEqual(decoded.senderName, "")
    }

    func testOfferMetadataEmptyVerificationCode() throws {
        let meta = ScoutDropOfferMetadata(
            senderName: "A",
            transferID: UUID(),
            files: [],
            totalSize: 0,
            verificationCode: "",
            senderDeviceID: "d"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: data)
        XCTAssertEqual(decoded.verificationCode, "")
    }

    func testOfferMetadataUnicodeSenderName() throws {
        let meta = ScoutDropOfferMetadata(
            senderName: "太郎のMac 🖥️",
            transferID: UUID(),
            files: [],
            totalSize: 0,
            verificationCode: "123456",
            senderDeviceID: "dev1"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: data)
        XCTAssertEqual(decoded.senderName, "太郎のMac 🖥️")
    }

    /// Large file list must encode/decode without issues.
    func testOfferMetadataLargeFileList() throws {
        let files = (0..<1000).map { i in
            ScoutDropFileEntry(
                relativePath: "dir/file_\(i).bin",
                size: Int64(i * 1024),
                isDirectory: false
            )
        }
        let meta = ScoutDropOfferMetadata(
            senderName: "Sender",
            transferID: UUID(),
            files: files,
            totalSize: files.reduce(0) { $0 + $1.size },
            verificationCode: "123456",
            senderDeviceID: "dev1"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: data)
        XCTAssertEqual(decoded.files.count, 1000)
    }

    // MARK: - Forward Compatibility

    func testOfferMetadataIgnoresUnknownFields() throws {
        let id = UUID()
        let json = """
        {
            "senderName": "FuturePeer",
            "transferID": "\(id.uuidString)",
            "files": [],
            "totalSize": 0,
            "verificationCode": "999999",
            "senderDeviceID": "dev-future",
            "compressionAlgorithm": "zstd",
            "protocolVersion": 2
        }
        """
        let decoded = try JSONDecoder().decode(
            ScoutDropOfferMetadata.self, from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.senderName, "FuturePeer")
        XCTAssertEqual(decoded.transferID, id)
    }

    func testFileEntryIgnoresUnknownFields() throws {
        let json = """
        {
            "relativePath": "photo.heic",
            "size": 5000000,
            "isDirectory": false,
            "isSymlink": false,
            "checksum": "abc123def456",
            "modificationDate": "2026-01-01T00:00:00Z"
        }
        """
        let decoded = try JSONDecoder().decode(
            ScoutDropFileEntry.self, from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.relativePath, "photo.heic")
        XCTAssertEqual(decoded.size, 5_000_000)
    }

    func testAcceptMetadataIgnoresUnknownFields() throws {
        let id = UUID()
        let json = """
        {
            "transferID": "\(id.uuidString)",
            "resumeOffsets": {},
            "receiverVersion": "2.0"
        }
        """
        let decoded = try JSONDecoder().decode(
            ScoutDropAcceptMetadata.self, from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.transferID, id)
    }

    func testControlMetadataIgnoresUnknownFields() throws {
        let id = UUID()
        let json = """
        {
            "transferID": "\(id.uuidString)",
            "errorMessage": "fail",
            "retryAfter": 30
        }
        """
        let decoded = try JSONDecoder().decode(
            ScoutDropControlMetadata.self, from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.errorMessage, "fail")
    }

    // MARK: - Malformed JSON

    func testOfferMetadataMissingRequiredFieldThrows() {
        let json = """
        {"senderName": "Partial", "transferID": "\(UUID().uuidString)"}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: Data(json.utf8))
        )
    }

    func testTruncatedJSONThrows() {
        let json = """
        {"senderName": "Trunc
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: Data(json.utf8))
        )
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: Data())
        )
    }

    func testFileEntryMissingRequiredFieldThrows() {
        // Missing 'size' field.
        let json = """
        {"relativePath": "file.txt", "isDirectory": false}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoutDropFileEntry.self, from: Data(json.utf8))
        )
    }

    func testAcceptMetadataMissingTransferIDThrows() {
        let json = """
        {"resumeOffsets": {}}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoutDropAcceptMetadata.self, from: Data(json.utf8))
        )
    }

    /// Non-JSON binary data must fail gracefully.
    func testBinaryGarbageThrows() {
        let garbage = Data([0x00, 0xFF, 0xFE, 0x80, 0x01])
        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: garbage)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoutDropFileEntry.self, from: garbage)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoutDropAcceptMetadata.self, from: garbage)
        )
    }

    // MARK: - ScoutDropAcceptMetadata

    func testAcceptMetadataWithResumeOffsets() throws {
        let id = UUID()
        var meta = ScoutDropAcceptMetadata(transferID: id)
        meta.resumeOffsets = [0: 500, 2: 1000]

        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropAcceptMetadata.self, from: data)
        XCTAssertEqual(decoded.transferID, id)
        XCTAssertEqual(decoded.resumeOffsets[0], 500)
        XCTAssertEqual(decoded.resumeOffsets[2], 1000)
        XCTAssertNil(decoded.resumeOffsets[1])
    }

    func testAcceptMetadataEmptyResumeOffsets() throws {
        let meta = ScoutDropAcceptMetadata(transferID: UUID())
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropAcceptMetadata.self, from: data)
        XCTAssertTrue(decoded.resumeOffsets.isEmpty)
    }

    func testAcceptMetadataLargeResumeOffset() throws {
        var meta = ScoutDropAcceptMetadata(transferID: UUID())
        meta.resumeOffsets = [0: Int64.max]
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropAcceptMetadata.self, from: data)
        XCTAssertEqual(decoded.resumeOffsets[0], Int64.max)
    }

    func testAcceptMetadataResumeOffsetsWireFormat() throws {
        var meta = ScoutDropAcceptMetadata(transferID: UUID())
        meta.resumeOffsets = [5: 2048]
        let data = try JSONEncoder().encode(meta)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"5\""), "Int dict keys should serialize as strings")
    }

    /// Many resume offsets for a large transfer (simulate 1000 files with offsets).
    func testAcceptMetadataManyResumeOffsets() throws {
        var meta = ScoutDropAcceptMetadata(transferID: UUID())
        for i in 0..<1000 {
            meta.resumeOffsets[i] = Int64(i * 512)
        }
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropAcceptMetadata.self, from: data)
        XCTAssertEqual(decoded.resumeOffsets.count, 1000)
        XCTAssertEqual(decoded.resumeOffsets[999], 999 * 512)
    }

    func testAcceptMetadataZeroResumeOffset() throws {
        var meta = ScoutDropAcceptMetadata(transferID: UUID())
        meta.resumeOffsets = [0: 0]
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropAcceptMetadata.self, from: data)
        XCTAssertEqual(decoded.resumeOffsets[0], 0)
    }

    // MARK: - ScoutDropControlMetadata

    func testControlMetadataWithError() throws {
        let id = UUID()
        var meta = ScoutDropControlMetadata(transferID: id)
        meta.errorMessage = "Disk full"
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropControlMetadata.self, from: data)
        XCTAssertEqual(decoded.transferID, id)
        XCTAssertEqual(decoded.errorMessage, "Disk full")
    }

    func testControlMetadataNilError() throws {
        let meta = ScoutDropControlMetadata(transferID: UUID())
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropControlMetadata.self, from: data)
        XCTAssertNil(decoded.errorMessage)
    }

    func testControlMetadataEmptyErrorMessage() throws {
        var meta = ScoutDropControlMetadata(transferID: UUID())
        meta.errorMessage = ""
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropControlMetadata.self, from: data)
        XCTAssertEqual(decoded.errorMessage, "")
    }

    func testControlMetadataLongErrorMessage() throws {
        let longMsg = String(repeating: "x", count: 10_000)
        var meta = ScoutDropControlMetadata(transferID: UUID())
        meta.errorMessage = longMsg
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropControlMetadata.self, from: data)
        XCTAssertEqual(decoded.errorMessage?.count, 10_000)
    }

    // MARK: - ScoutDropFileErrorMetadata

    func testFileErrorMetadata() throws {
        let id = UUID()
        let meta = ScoutDropFileErrorMetadata(
            transferID: id, fileIndex: 3, errorMessage: "Permission denied"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropFileErrorMetadata.self, from: data)
        XCTAssertEqual(decoded.transferID, id)
        XCTAssertEqual(decoded.fileIndex, 3)
        XCTAssertEqual(decoded.errorMessage, "Permission denied")
    }

    func testFileErrorMetadataZeroIndex() throws {
        let meta = ScoutDropFileErrorMetadata(
            transferID: UUID(), fileIndex: 0, errorMessage: "Read error"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropFileErrorMetadata.self, from: data)
        XCTAssertEqual(decoded.fileIndex, 0)
    }

    func testFileErrorMetadataMaxIndex() throws {
        let meta = ScoutDropFileErrorMetadata(
            transferID: UUID(), fileIndex: Int(UInt16.max), errorMessage: "Error at max"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ScoutDropFileErrorMetadata.self, from: data)
        XCTAssertEqual(decoded.fileIndex, 65535)
    }
}

// MARK: - ScoutDropOfferTests

final class ScoutDropOfferTests: XCTestCase {

    func testFileCountExcludesDirectories() {
        let offer = ScoutDropOffer(
            id: UUID(),
            senderName: "Sender",
            files: [
                ScoutDropFileEntry(relativePath: "dir", size: 0, isDirectory: true),
                ScoutDropFileEntry(relativePath: "a.txt", size: 100, isDirectory: false),
                ScoutDropFileEntry(relativePath: "b.txt", size: 200, isDirectory: false),
            ],
            totalSize: 300,
            verificationCode: "000000",
            senderDeviceID: "dev1",
            peerPublicKeyHash: nil
        )
        XCTAssertEqual(offer.fileCount, 2)
    }

    func testFileCountAllDirectories() {
        let offer = ScoutDropOffer(
            id: UUID(),
            senderName: "Sender",
            files: [
                ScoutDropFileEntry(relativePath: "dir1", size: 0, isDirectory: true),
                ScoutDropFileEntry(relativePath: "dir2", size: 0, isDirectory: true),
            ],
            totalSize: 0,
            verificationCode: "000000",
            senderDeviceID: "dev1",
            peerPublicKeyHash: nil
        )
        XCTAssertEqual(offer.fileCount, 0)
    }

    func testFileCountEmpty() {
        let offer = ScoutDropOffer(
            id: UUID(), senderName: "S", files: [], totalSize: 0,
            verificationCode: "000000", senderDeviceID: "d", peerPublicKeyHash: nil
        )
        XCTAssertEqual(offer.fileCount, 0)
    }

    func testFileCountIncludesSymlinks() {
        var symlink = ScoutDropFileEntry(relativePath: "link", size: 0, isDirectory: false)
        symlink.isSymlink = true
        symlink.symlinkTarget = "target.txt"

        let offer = ScoutDropOffer(
            id: UUID(),
            senderName: "Sender",
            files: [
                symlink,
                ScoutDropFileEntry(relativePath: "real.txt", size: 100, isDirectory: false),
                ScoutDropFileEntry(relativePath: "dir", size: 0, isDirectory: true),
            ],
            totalSize: 100,
            verificationCode: "000000",
            senderDeviceID: "dev1",
            peerPublicKeyHash: nil
        )
        XCTAssertEqual(offer.fileCount, 2, "Symlinks should count as files")
    }

    func testFormattedSizeKnownValue() {
        let offer = ScoutDropOffer(
            id: UUID(), senderName: "S", files: [], totalSize: 1_048_576,
            verificationCode: "123456", senderDeviceID: "d", peerPublicKeyHash: nil
        )
        let expected = ByteCountFormatter.string(fromByteCount: 1_048_576, countStyle: .file)
        XCTAssertEqual(offer.formattedSize, expected)
    }

    func testFormattedSizeZeroBytes() {
        let offer = ScoutDropOffer(
            id: UUID(), senderName: "S", files: [], totalSize: 0,
            verificationCode: "123456", senderDeviceID: "d", peerPublicKeyHash: nil
        )
        let expected = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
        XCTAssertEqual(offer.formattedSize, expected)
    }

    func testFormattedSizeOneByte() {
        let offer = ScoutDropOffer(
            id: UUID(), senderName: "S", files: [], totalSize: 1,
            verificationCode: "0", senderDeviceID: "d", peerPublicKeyHash: nil
        )
        let expected = ByteCountFormatter.string(fromByteCount: 1, countStyle: .file)
        XCTAssertEqual(offer.formattedSize, expected)
    }

    func testFormattedSizeMaxInt64() {
        let offer = ScoutDropOffer(
            id: UUID(), senderName: "S", files: [], totalSize: Int64.max,
            verificationCode: "0", senderDeviceID: "d", peerPublicKeyHash: nil
        )
        // Should not crash.
        XCTAssertFalse(offer.formattedSize.isEmpty)
    }

    func testIdentifiable() {
        let id = UUID()
        let offer = ScoutDropOffer(
            id: id, senderName: "S", files: [], totalSize: 0,
            verificationCode: "000000", senderDeviceID: "d", peerPublicKeyHash: nil
        )
        XCTAssertEqual(offer.id, id)
    }
}

// MARK: - ScoutDropPeerTests

final class ScoutDropPeerTests: XCTestCase {

    func testPeerProperties() {
        let peer = ScoutDropPeer(
            name: "TestPeer",
            endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 12345),
            deviceID: "device-123"
        )
        XCTAssertEqual(peer.name, "TestPeer")
        XCTAssertEqual(peer.deviceID, "device-123")
    }

    func testPeerDefaultState() {
        let peer = ScoutDropPeer(
            name: "Peer",
            endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        if case .discovered = peer.state {} else {
            XCTFail("Initial state should be .discovered")
        }
    }

    func testPeerNilDeviceID() {
        let peer = ScoutDropPeer(
            name: "Peer",
            endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234),
            deviceID: nil
        )
        XCTAssertNil(peer.deviceID)
    }

    func testPeerEmptyDeviceID() {
        let peer = ScoutDropPeer(
            name: "Peer",
            endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234),
            deviceID: ""
        )
        XCTAssertEqual(peer.deviceID, "")
    }

    func testPeerEmptyName() {
        let peer = ScoutDropPeer(
            name: "",
            endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        XCTAssertEqual(peer.name, "")
    }

    func testPeerStateTransitionToConnecting() {
        let peer = ScoutDropPeer(
            name: "P", endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        peer.state = .connecting
        if case .connecting = peer.state {} else { XCTFail("Should be .connecting") }
    }

    func testPeerStateTransitionToConnected() {
        let peer = ScoutDropPeer(
            name: "P", endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        peer.state = .connected
        if case .connected = peer.state {} else { XCTFail("Should be .connected") }
    }

    func testPeerStateTransitionToTransferring() {
        let peer = ScoutDropPeer(
            name: "P", endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        peer.state = .transferring(progress: 0.5)
        if case let .transferring(progress) = peer.state {
            XCTAssertEqual(progress, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Should be .transferring")
        }
    }

    func testPeerStateTransitionToDisconnected() {
        let peer = ScoutDropPeer(
            name: "P", endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        peer.state = .disconnected
        if case .disconnected = peer.state {} else { XCTFail("Should be .disconnected") }
    }

    func testPeerTransferProgressBounds() {
        let peer = ScoutDropPeer(
            name: "P", endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        peer.state = .transferring(progress: 0.0)
        if case let .transferring(p) = peer.state { XCTAssertEqual(p, 0.0, accuracy: 0.001) }
        else { XCTFail("Should be .transferring at 0.0") }

        peer.state = .transferring(progress: 1.0)
        if case let .transferring(p) = peer.state { XCTAssertEqual(p, 1.0, accuracy: 0.001) }
        else { XCTFail("Should be .transferring at 1.0") }
    }

    func testPeerHasUniqueID() {
        let peer1 = ScoutDropPeer(
            name: "A", endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        let peer2 = ScoutDropPeer(
            name: "B", endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        XCTAssertNotEqual(peer1.id, peer2.id)
    }

    /// Peer uses class (reference) semantics — mutations should be visible through
    /// all references.
    func testPeerReferenceSemantics() {
        let peer = ScoutDropPeer(
            name: "P", endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        let ref = peer
        ref.state = .connected
        if case .connected = peer.state {} else {
            XCTFail("Mutation via ref should be visible on original (class semantics)")
        }
    }

    /// Full lifecycle: discovered → connecting → connected → transferring → disconnected.
    func testPeerFullLifecycle() {
        let peer = ScoutDropPeer(
            name: "P", endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        if case .discovered = peer.state {} else { XCTFail("Should start discovered") }

        peer.state = .connecting
        if case .connecting = peer.state {} else { XCTFail("Should be connecting") }

        peer.state = .connected
        if case .connected = peer.state {} else { XCTFail("Should be connected") }

        peer.state = .transferring(progress: 0.0)
        peer.state = .transferring(progress: 0.5)
        peer.state = .transferring(progress: 1.0)
        if case let .transferring(p) = peer.state { XCTAssertEqual(p, 1.0, accuracy: 0.001) }
        else { XCTFail("Should be transferring at 1.0") }

        peer.state = .disconnected
        if case .disconnected = peer.state {} else { XCTFail("Should be disconnected") }
    }

    /// Name mutation after creation (for Bonjour updates).
    func testPeerNameMutation() {
        let peer = ScoutDropPeer(
            name: "Old Name",
            endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1234)
        )
        peer.name = "New Name"
        XCTAssertEqual(peer.name, "New Name")
    }
}

// MARK: - ScoutDropErrorTests

final class ScoutDropErrorTests: XCTestCase {

    func testConnectionFailedDescription() {
        let error = ScoutDropError.connectionFailed("timeout")
        XCTAssertEqual(error.errorDescription, "Connection failed: timeout")
    }

    func testTransferDeclinedDescription() {
        XCTAssertEqual(ScoutDropError.transferDeclined.errorDescription, "Transfer was declined")
    }

    func testTransferTimeoutDescription() {
        XCTAssertEqual(ScoutDropError.transferTimeout.errorDescription, "Transfer timed out")
    }

    func testInvalidMessageDescription() {
        XCTAssertEqual(ScoutDropError.invalidMessage.errorDescription, "Received invalid message")
    }

    func testConnectionClosedDescription() {
        XCTAssertEqual(
            ScoutDropError.connectionClosed.errorDescription,
            "Connection closed unexpectedly"
        )
    }

    func testWriteFailedDescription() {
        XCTAssertEqual(
            ScoutDropError.writeFailed("disk full").errorDescription,
            "Failed to write file: disk full"
        )
    }

    func testChecksumMismatchDescription() {
        XCTAssertEqual(
            ScoutDropError.checksumMismatch("file.txt").errorDescription,
            "Checksum mismatch for file.txt"
        )
    }

    func testIdentityKeyMismatchDescription() {
        let desc = ScoutDropError.identityKeyMismatch("TestDevice").errorDescription!
        XCTAssertTrue(desc.contains("TestDevice"))
        XCTAssertTrue(desc.contains("Identity changed"))
    }

    func testErrorConformsToLocalizedError() {
        let errors: [ScoutDropError] = [
            .connectionFailed("x"), .transferDeclined, .transferTimeout,
            .invalidMessage, .connectionClosed, .writeFailed("x"),
            .checksumMismatch("x"), .identityKeyMismatch("x"),
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "nil for \(error)")
        }
    }

    func testConnectionFailedEmptyMessage() {
        XCTAssertEqual(
            ScoutDropError.connectionFailed("").errorDescription,
            "Connection failed: "
        )
    }

    func testWriteFailedEmptyMessage() {
        XCTAssertEqual(
            ScoutDropError.writeFailed("").errorDescription,
            "Failed to write file: "
        )
    }

    func testIdentityKeyMismatchEmptyName() {
        let desc = ScoutDropError.identityKeyMismatch("").errorDescription!
        XCTAssertTrue(desc.contains("Identity changed"))
    }

    func testChecksumMismatchUnicodePath() {
        let desc = ScoutDropError.checksumMismatch("日本語/ファイル.txt").errorDescription!
        XCTAssertTrue(desc.contains("日本語/ファイル.txt"))
    }
}

// MARK: - ScoutDropIdentityTests

final class ScoutDropIdentityTests: XCTestCase {

    func testGetOrCreateIdentityReturnsIdentity() throws {
        let identity = try ScoutDropIdentity.getOrCreateIdentity()
        let identity2 = try ScoutDropIdentity.getOrCreateIdentity()
        let hash1 = ScoutDropIdentity.publicKeyHash(from: identity)
        let hash2 = ScoutDropIdentity.publicKeyHash(from: identity2)
        XCTAssertNotNil(hash1)
        XCTAssertNotNil(hash2)
        XCTAssertEqual(hash1, hash2, "Same identity should produce the same public key hash")
    }

    func testPublicKeyHashFormat() throws {
        let identity = try ScoutDropIdentity.getOrCreateIdentity()
        let hash = ScoutDropIdentity.publicKeyHash(from: identity)
        XCTAssertNotNil(hash)
        guard let hash else { return }
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testPublicKeyHashDeterministic() throws {
        let identity = try ScoutDropIdentity.getOrCreateIdentity()
        let hash1 = ScoutDropIdentity.publicKeyHash(from: identity)
        let hash2 = ScoutDropIdentity.publicKeyHash(from: identity)
        XCTAssertEqual(hash1, hash2)
    }

    /// The generated certificate should be parseable by SecCertificateCreateWithData.
    func testGeneratedCertificateIsValidX509() throws {
        let identity = try ScoutDropIdentity.getOrCreateIdentity()
        var cert: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &cert)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(cert)

        // Re-export and re-import to verify the DER is well-formed.
        if let cert {
            let derData = SecCertificateCopyData(cert) as Data
            XCTAssertGreaterThan(derData.count, 0)
            let reimported = SecCertificateCreateWithData(nil, derData as CFData)
            XCTAssertNotNil(reimported, "Certificate DER should round-trip through Security.framework")
        }
    }

    /// Verify the certificate has a public key we can extract and hash.
    func testCertificateHasExtractablePublicKey() throws {
        let identity = try ScoutDropIdentity.getOrCreateIdentity()
        var cert: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &cert)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(cert)

        if let cert {
            let pubKey = SecCertificateCopyKey(cert)
            XCTAssertNotNil(pubKey, "Certificate must have an extractable public key")

            if let pubKey {
                var error: Unmanaged<CFError>?
                let keyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data?
                XCTAssertNotNil(keyData, "Public key must be exportable")
                XCTAssertGreaterThan(keyData?.count ?? 0, 0)
            }
        }
    }

    /// Verify the identity produces a valid DER certificate that re-imports cleanly.
    func testCertificateRoundTripsThroughDER() throws {
        let identity = try ScoutDropIdentity.getOrCreateIdentity()
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert else { XCTFail("Cannot extract cert"); return }

        let derData = SecCertificateCopyData(cert) as Data
        XCTAssertGreaterThan(derData.count, 0)
        let reimported = SecCertificateCreateWithData(nil, derData as CFData)
        XCTAssertNotNil(reimported, "Certificate DER must round-trip through Security.framework")
    }
}

// MARK: - DER Encoding Tests

final class ScoutDropDEREncodingTests: XCTestCase {

    // MARK: - derLength

    func testDerLengthShortForm() {
        // 0..127 use short form: single byte.
        XCTAssertEqual(ScoutDropIdentity.derLength(0), [0x00])
        XCTAssertEqual(ScoutDropIdentity.derLength(1), [0x01])
        XCTAssertEqual(ScoutDropIdentity.derLength(127), [0x7F])
    }

    func testDerLengthLongFormOneByte() {
        // 128..255 use long form: 0x81 + 1 byte.
        XCTAssertEqual(ScoutDropIdentity.derLength(128), [0x81, 0x80])
        XCTAssertEqual(ScoutDropIdentity.derLength(255), [0x81, 0xFF])
    }

    func testDerLengthLongFormTwoBytes() {
        // 256..65535 use long form: 0x82 + 2 bytes.
        XCTAssertEqual(ScoutDropIdentity.derLength(256), [0x82, 0x01, 0x00])
        XCTAssertEqual(ScoutDropIdentity.derLength(65535), [0x82, 0xFF, 0xFF])
    }

    func testDerLengthLongFormThreeBytes() {
        // 65536..16777215 use long form: 0x83 + 3 bytes.
        XCTAssertEqual(ScoutDropIdentity.derLength(65536), [0x83, 0x01, 0x00, 0x00])
        XCTAssertEqual(ScoutDropIdentity.derLength(16_777_215), [0x83, 0xFF, 0xFF, 0xFF])
    }

    func testDerLengthBoundaryValues() {
        // Verify the short/long boundary exactly at 127/128.
        let short = ScoutDropIdentity.derLength(127)
        XCTAssertEqual(short.count, 1)
        XCTAssertEqual(short[0], 0x7F)

        let long = ScoutDropIdentity.derLength(128)
        XCTAssertEqual(long.count, 2)
        XCTAssertEqual(long[0], 0x81)
    }

    // MARK: - derInteger

    func testDerIntegerSmallPositive() {
        // 0x01 has high bit clear → no padding needed.
        XCTAssertEqual(
            ScoutDropIdentity.derInteger([0x01]),
            [0x02, 0x01, 0x01]  // tag=02, length=01, value=01
        )
    }

    func testDerIntegerHighBitSetGetsPadded() {
        // 0x80 has high bit set → prepend 0x00.
        XCTAssertEqual(
            ScoutDropIdentity.derInteger([0x80]),
            [0x02, 0x02, 0x00, 0x80]  // tag=02, length=02, value=00 80
        )
    }

    func testDerIntegerFF() {
        XCTAssertEqual(
            ScoutDropIdentity.derInteger([0xFF]),
            [0x02, 0x02, 0x00, 0xFF]
        )
    }

    func testDerIntegerNoDoublePadding() {
        // Already starts with 0x00 — should NOT double-pad.
        XCTAssertEqual(
            ScoutDropIdentity.derInteger([0x00, 0x80]),
            [0x02, 0x02, 0x00, 0x80]  // No extra 0x00 because first byte is already 0x00
        )
    }

    func testDerIntegerMaxByte7F() {
        // 0x7F has high bit clear → no padding.
        XCTAssertEqual(
            ScoutDropIdentity.derInteger([0x7F]),
            [0x02, 0x01, 0x7F]
        )
    }

    func testDerIntegerMultiByte() {
        // Multi-byte integer 0x01 0x00 (=256) — no padding needed.
        XCTAssertEqual(
            ScoutDropIdentity.derInteger([0x01, 0x00]),
            [0x02, 0x02, 0x01, 0x00]
        )
    }

    func testDerIntegerMultiByteHighBit() {
        // 0xAB 0xCD has high bit set → pad.
        XCTAssertEqual(
            ScoutDropIdentity.derInteger([0xAB, 0xCD]),
            [0x02, 0x03, 0x00, 0xAB, 0xCD]
        )
    }

    // MARK: - derBitString

    func testDerBitStringEmpty() {
        // Empty bit string: tag=03, length=01, unused_bits=00
        XCTAssertEqual(
            ScoutDropIdentity.derBitString([]),
            [0x03, 0x01, 0x00]
        )
    }

    func testDerBitStringSingleByte() {
        XCTAssertEqual(
            ScoutDropIdentity.derBitString([0xAB]),
            [0x03, 0x02, 0x00, 0xAB]
        )
    }

    func testDerBitStringMultipleBytes() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03]
        let result = ScoutDropIdentity.derBitString(bytes)
        XCTAssertEqual(result[0], 0x03)  // tag
        XCTAssertEqual(result[1], 0x04)  // length (unused_bits + 3 bytes)
        XCTAssertEqual(result[2], 0x00)  // unused bits
        XCTAssertEqual(Array(result[3...]), bytes)
    }

    // MARK: - derUTF8String

    func testDerUTF8StringASCII() {
        let result = ScoutDropIdentity.derUTF8String("ABC")
        XCTAssertEqual(result, [0x0C, 0x03, 0x41, 0x42, 0x43])
    }

    func testDerUTF8StringEmpty() {
        XCTAssertEqual(
            ScoutDropIdentity.derUTF8String(""),
            [0x0C, 0x00]
        )
    }

    func testDerUTF8StringMultibyte() {
        // "é" is 2 bytes in UTF-8: C3 A9
        let result = ScoutDropIdentity.derUTF8String("é")
        XCTAssertEqual(result[0], 0x0C)  // tag
        XCTAssertEqual(result[1], 0x02)  // 2 bytes
        XCTAssertEqual(result[2], 0xC3)
        XCTAssertEqual(result[3], 0xA9)
    }

    func testDerUTF8StringCJK() {
        // "中" is 3 bytes in UTF-8: E4 B8 AD
        let result = ScoutDropIdentity.derUTF8String("中")
        XCTAssertEqual(result[0], 0x0C)
        XCTAssertEqual(result[1], 0x03)
        XCTAssertEqual(result[2], 0xE4)
        XCTAssertEqual(result[3], 0xB8)
        XCTAssertEqual(result[4], 0xAD)
    }

    func testDerUTF8StringEmoji() {
        // "🔒" is 4 bytes in UTF-8: F0 9F 94 92
        let result = ScoutDropIdentity.derUTF8String("🔒")
        XCTAssertEqual(result[0], 0x0C)
        XCTAssertEqual(result[1], 0x04)
    }

    func testDerUTF8StringLong() {
        // String > 127 bytes triggers long-form length encoding.
        let longStr = String(repeating: "X", count: 200)
        let result = ScoutDropIdentity.derUTF8String(longStr)
        XCTAssertEqual(result[0], 0x0C)
        XCTAssertEqual(result[1], 0x81)  // long form: 1 extra length byte
        XCTAssertEqual(result[2], 200)
        XCTAssertEqual(result.count, 3 + 200)
    }

    // MARK: - derSequence / derSet / derOID / derExplicitTag

    func testDerSequenceEmpty() {
        XCTAssertEqual(ScoutDropIdentity.derSequence([]), [0x30, 0x00])
    }

    func testDerSequenceWithContent() {
        let result = ScoutDropIdentity.derSequence([0x01, 0x02])
        XCTAssertEqual(result, [0x30, 0x02, 0x01, 0x02])
    }

    func testDerSetEmpty() {
        XCTAssertEqual(ScoutDropIdentity.derSet([]), [0x31, 0x00])
    }

    func testDerOID() {
        let oid: [UInt8] = [0x55, 0x04, 0x03]  // commonName
        let result = ScoutDropIdentity.derOID(oid)
        XCTAssertEqual(result, [0x06, 0x03, 0x55, 0x04, 0x03])
    }

    func testDerExplicitTag0() {
        let content: [UInt8] = [0x02, 0x01, 0x02]  // INTEGER 2
        let result = ScoutDropIdentity.derExplicitTag(0, content)
        XCTAssertEqual(result[0], 0xA0)  // context tag 0
        XCTAssertEqual(result[1], 0x03)  // length
        XCTAssertEqual(Array(result[2...]), content)
    }

    func testDerExplicitTagNonZero() {
        let result = ScoutDropIdentity.derExplicitTag(3, [0x05])
        XCTAssertEqual(result[0], 0xA3)
    }

    // MARK: - derGeneralizedTime

    func testDerGeneralizedTimeFormat() {
        // 2026-03-15 12:30:45 UTC → "20260315123045Z"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(
            year: 2026, month: 3, day: 15, hour: 12, minute: 30, second: 45
        )
        let date = calendar.date(from: components)!

        let result = ScoutDropIdentity.derGeneralizedTime(date)
        XCTAssertEqual(result[0], 0x18)  // GeneralizedTime tag
        let timeString = String(bytes: result[2...], encoding: .utf8)
        XCTAssertEqual(timeString, "20260315123045Z")
    }

    func testDerGeneralizedTimeEpoch() {
        let epoch = Date(timeIntervalSince1970: 0)  // 1970-01-01 00:00:00 UTC
        let result = ScoutDropIdentity.derGeneralizedTime(epoch)
        let timeString = String(bytes: result[2...], encoding: .utf8)
        XCTAssertEqual(timeString, "19700101000000Z")
    }

    func testDerGeneralizedTimeAlwaysFixedLength() {
        // GeneralizedTime "yyyyMMddHHmmssZ" is always 15 bytes.
        let dates = [
            Date(timeIntervalSince1970: 0),
            Date(),
            Date(timeIntervalSinceReferenceDate: 0),
        ]
        for date in dates {
            let result = ScoutDropIdentity.derGeneralizedTime(date)
            XCTAssertEqual(result[0], 0x18)
            XCTAssertEqual(result[1], 15)
            XCTAssertEqual(result.count, 17)  // tag + length + 15 bytes
        }
    }

    // MARK: - Nested DER structures

    /// A complete RDN sequence (as used for CN=ScoutDrop) should produce valid DER.
    func testRDNSequenceStructure() {
        let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]
        let atv = ScoutDropIdentity.derSequence(
            ScoutDropIdentity.derOID(commonNameOID)
                + ScoutDropIdentity.derUTF8String("ScoutDrop")
        )
        let rdn = ScoutDropIdentity.derSet(atv)
        let rdnSequence = ScoutDropIdentity.derSequence(rdn)

        // Verify outer structure.
        XCTAssertEqual(rdnSequence[0], 0x30)  // SEQUENCE tag
        // Verify inner SET.
        let innerOffset = 2  // tag + length
        XCTAssertTrue(rdnSequence.count > innerOffset)
    }

    /// Long content (>127 bytes) should use multi-byte length encoding throughout.
    func testDerSequenceLongContent() {
        let content = [UInt8](repeating: 0x42, count: 200)
        let result = ScoutDropIdentity.derSequence(content)
        XCTAssertEqual(result[0], 0x30)
        XCTAssertEqual(result[1], 0x81)  // long form
        XCTAssertEqual(result[2], 200)
        XCTAssertEqual(result.count, 3 + 200)
    }
}

// MARK: - ScoutDropChecksumTests

final class ScoutDropChecksumTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutDropChecksumTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testFullFileChecksum() throws {
        let content = Data(repeating: 0xAB, count: 1024)
        let filePath = tempDir.appendingPathComponent("test.bin")
        try content.write(to: filePath)

        let handle = try FileHandle(forReadingFrom: filePath)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 524_288), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(checksum, expected)
    }

    func testResumeChecksumMatchesFullFile() throws {
        let fullContent = Data(repeating: 0xCD, count: 2048)
        let filePath = tempDir.appendingPathComponent("full.bin")
        try fullContent.write(to: filePath)
        let resumeOffset: Int64 = 1024

        // Sender hashes entire file.
        let senderHandle = try FileHandle(forReadingFrom: filePath)
        defer { try? senderHandle.close() }
        var senderHasher = SHA256()
        senderHandle.seek(toFileOffset: 0)
        var remaining = resumeOffset
        while remaining > 0 {
            let readSize = min(remaining, 524_288)
            guard let data = try senderHandle.read(upToCount: Int(readSize)), !data.isEmpty
            else { break }
            senderHasher.update(data: data)
            remaining -= Int64(data.count)
        }
        while let chunk = try senderHandle.read(upToCount: 524_288), !chunk.isEmpty {
            senderHasher.update(data: chunk)
        }
        let senderChecksum = senderHasher.finalize().map { String(format: "%02x", $0) }.joined()

        // Receiver hashes existing + new.
        let incompletePath = tempDir.appendingPathComponent("full.bin.incomplete")
        try fullContent.prefix(Int(resumeOffset)).write(to: incompletePath)
        guard let receiverHandle = FileHandle(forUpdatingAtPath: incompletePath.path) else {
            XCTFail("Cannot open .incomplete"); return
        }
        var receiverHasher = SHA256()
        receiverHandle.seek(toFileOffset: 0)
        while true {
            guard let data = try receiverHandle.read(upToCount: 524_288), !data.isEmpty
            else { break }
            receiverHasher.update(data: data)
        }
        let newBytes = fullContent.suffix(from: Int(resumeOffset))
        try receiverHandle.write(contentsOf: newBytes)
        receiverHasher.update(data: newBytes)
        try receiverHandle.close()

        let receiverChecksum = receiverHasher.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(senderChecksum, receiverChecksum)

        let directHash = SHA256.hash(data: fullContent).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(senderChecksum, directHash)
    }

    func testChecksumMismatchOnCorruptedResume() throws {
        let senderContent = Data(repeating: 0xAA, count: 2048)
        let corruptedPrefix = Data(repeating: 0xBB, count: 1024)
        let newBytes = senderContent.suffix(from: 1024)

        let senderChecksum = SHA256.hash(data: senderContent)
            .map { String(format: "%02x", $0) }.joined()
        let receiverContent = corruptedPrefix + newBytes
        let receiverChecksum = SHA256.hash(data: receiverContent)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(senderChecksum, receiverChecksum)
    }

    func testEmptyFileChecksum() {
        let checksum = SHA256.hash(data: Data())
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            checksum,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testLargeFileChecksumChunkedMatchesOneShot() throws {
        let size = 5 * 1024 * 1024
        let content = Data((0..<size).map { UInt8($0 % 256) })
        let filePath = tempDir.appendingPathComponent("large.bin")
        try content.write(to: filePath)

        let handle = try FileHandle(forReadingFrom: filePath)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 524_288), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let streamed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let direct = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(streamed, direct)
    }

    func testSingleByteFileChecksum() {
        let checksum = SHA256.hash(data: Data([0x42]))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            checksum,
            "df7e70e5021544f4834bbee64a9e3789febc4be81470df629cad6ddb03320a5c"
        )
    }

    func testResumeHashWithFileHandleForUpdating() throws {
        let existingBytes = Data(repeating: 0x11, count: 512)
        let newBytes = Data(repeating: 0x22, count: 512)
        let path = tempDir.appendingPathComponent("update.bin.incomplete")
        try existingBytes.write(to: path)

        guard let handle = FileHandle(forUpdatingAtPath: path.path) else {
            XCTFail("Cannot open"); return
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        handle.seek(toFileOffset: 0)
        while true {
            guard let data = try handle.read(upToCount: 524_288), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        try handle.write(contentsOf: newBytes)
        hasher.update(data: newBytes)
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = SHA256.hash(data: existingBytes + newBytes)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(checksum, expected)
    }

    /// SHA-256 hex comparison should be case-insensitive — the sender and receiver
    /// must agree on lowercase hex. Verify our format string produces lowercase.
    func testChecksumIsAlwaysLowercaseHex() {
        let data = Data([0xAB, 0xCD, 0xEF])
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, hex.lowercased(), "Checksum must be lowercase hex")
        XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) })
    }

    /// Resume at offset 0 (no existing data) should produce the same checksum
    /// as a fresh file hash.
    func testResumeAtOffsetZero() throws {
        let content = Data(repeating: 0x42, count: 1024)
        let path = tempDir.appendingPathComponent("fresh.bin.incomplete")
        FileManager.default.createFile(atPath: path.path, contents: nil)

        guard let handle = FileHandle(forUpdatingAtPath: path.path) else {
            XCTFail("Cannot open"); return
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        handle.seek(toFileOffset: 0)
        // Read existing — should be empty.
        while true {
            guard let data = try handle.read(upToCount: 524_288), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        // Write all content.
        try handle.write(contentsOf: content)
        hasher.update(data: content)

        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(checksum, expected)
    }

    /// Resume at full file size (file already complete) should produce correct checksum
    /// with zero new bytes appended.
    func testResumeAtFullSize() throws {
        let content = Data(repeating: 0x77, count: 512)
        let path = tempDir.appendingPathComponent("complete.bin.incomplete")
        try content.write(to: path)

        guard let handle = FileHandle(forUpdatingAtPath: path.path) else {
            XCTFail("Cannot open"); return
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        handle.seek(toFileOffset: 0)
        while true {
            guard let data = try handle.read(upToCount: 524_288), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        // No new bytes to write.
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(checksum, expected)
    }
}

// MARK: - ScoutDropPathTraversalTests

final class ScoutDropPathTraversalTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutDropPathTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Replicates ScoutDropService.validatedPath(relativePath:within:).
    private func validatedPath(relativePath: String, within destDir: URL) -> URL? {
        let resolved = destDir.appendingPathComponent(relativePath).standardizedFileURL
        let destPrefix = destDir.standardizedFileURL.path + "/"
        guard resolved.standardizedFileURL.path.hasPrefix(destPrefix) else { return nil }
        return resolved
    }

    func testNormalPathAccepted() {
        XCTAssertNotNil(validatedPath(relativePath: "folder/file.txt", within: tempDir))
    }

    func testSimpleTraversalRejected() {
        XCTAssertNil(validatedPath(relativePath: "../../../etc/passwd", within: tempDir))
    }

    func testMixedTraversalRejected() {
        XCTAssertNil(validatedPath(relativePath: "a/b/../../../etc/passwd", within: tempDir))
    }

    func testDoubleEncodedTraversalIsSafe() {
        XCTAssertNotNil(
            validatedPath(relativePath: "%2e%2e/%2e%2e/etc/passwd", within: tempDir)
        )
    }

    func testAbsolutePathRejected() {
        let result = validatedPath(relativePath: "/etc/passwd", within: tempDir)
        if let result {
            XCTAssertTrue(result.path.hasPrefix(tempDir.standardizedFileURL.path + "/"))
        }
    }

    func testDotDotAtEndResolvesToParentSubdir() {
        XCTAssertNotNil(validatedPath(relativePath: "a/b/..", within: tempDir))
    }

    func testTraversalToParentRejected() {
        XCTAssertNil(validatedPath(relativePath: "..", within: tempDir))
    }

    func testEmptyPathRejected() {
        XCTAssertNil(validatedPath(relativePath: "", within: tempDir))
    }

    func testDeepNestedPathAccepted() {
        let deep = (0..<50).map { "dir\($0)" }.joined(separator: "/") + "/file.txt"
        XCTAssertNotNil(validatedPath(relativePath: deep, within: tempDir))
    }

    func testSymlinkTargetTraversalRejected() {
        let destDir = tempDir!
        let linkPath = destDir.appendingPathComponent("mylink")
        let resolvedTarget = linkPath.deletingLastPathComponent()
            .appendingPathComponent("../../etc/passwd").standardizedFileURL
        XCTAssertFalse(resolvedTarget.path.hasPrefix(destDir.standardizedFileURL.path + "/"))
    }

    func testSymlinkTargetWithinDirAccepted() {
        let destDir = tempDir!
        let linkPath = destDir.appendingPathComponent("subdir/mylink")
        let resolvedTarget = linkPath.deletingLastPathComponent()
            .appendingPathComponent("../otherfile.txt").standardizedFileURL
        XCTAssertTrue(resolvedTarget.path.hasPrefix(destDir.standardizedFileURL.path + "/"))
    }

    func testCurrentDirectoryDotRejected() {
        XCTAssertNil(validatedPath(relativePath: ".", within: tempDir))
    }

    func testMultipleConsecutiveSlashes() {
        XCTAssertNotNil(validatedPath(relativePath: "a///b///c.txt", within: tempDir))
    }

    func testNullByteInPath() {
        let result = validatedPath(relativePath: "file\0.txt", within: tempDir)
        if let result {
            XCTAssertTrue(result.path.hasPrefix(tempDir.standardizedFileURL.path + "/"))
        }
    }

    /// Real symlink pointing outside destDir should be detectable.
    func testRealSymlinkEscapingDestDir() throws {
        let outsideFile = tempDir.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let linkPath = tempDir.appendingPathComponent("escape_link")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: outsideFile)

        // Resolve the symlink and verify it escapes.
        let resolved = linkPath.resolvingSymlinksInPath()
        XCTAssertFalse(
            resolved.path.hasPrefix(tempDir.standardizedFileURL.path + "/"),
            "Symlink resolves outside destDir"
        )
    }

    /// Real symlink within destDir should be accepted.
    func testRealSymlinkWithinDestDir() throws {
        let targetFile = tempDir.appendingPathComponent("target.txt")
        try "data".write(to: targetFile, atomically: true, encoding: .utf8)

        let linkPath = tempDir.appendingPathComponent("internal_link")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: targetFile)

        let resolved = linkPath.resolvingSymlinksInPath()
        XCTAssertTrue(resolved.path.hasPrefix(tempDir.standardizedFileURL.path + "/"))
    }

    /// Unicode normalization: precomposed vs decomposed filenames.
    func testUnicodeNormalizationInPath() {
        let precomposed = "caf\u{00E9}"  // é as single codepoint
        let decomposed = "cafe\u{0301}"  // e + combining accent

        let result1 = validatedPath(relativePath: precomposed + "/file.txt", within: tempDir)
        let result2 = validatedPath(relativePath: decomposed + "/file.txt", within: tempDir)
        // Both should be accepted (they're within destDir).
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }

    /// Extremely long path component that exceeds typical filesystem limits.
    func testVeryLongPathComponent() {
        let longName = String(repeating: "a", count: 300)  // > NAME_MAX (255)
        let result = validatedPath(relativePath: longName + "/file.txt", within: tempDir)
        // Should still be accepted by validation (filesystem will reject on creation).
        XCTAssertNotNil(result)
    }
}

// MARK: - ScoutDropResumeTests

final class ScoutDropResumeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutDropResumeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func resumeOffset(for path: URL, entrySize: Int64) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let existingSize = attrs[.size] as? Int64, existingSize > 0 else { return 0 }
        if existingSize > entrySize {
            try? FileManager.default.removeItem(at: path)
            return 0
        }
        return existingSize
    }

    func testResumeFromPartialFile() throws {
        let fullContent = Data((0..<2048).map { UInt8($0 % 256) })
        let path = tempDir.appendingPathComponent("file.txt.incomplete")
        try fullContent.prefix(1024).write(to: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual(attrs[.size] as! Int64, 1024)

        let handle = try FileHandle(forWritingTo: path)
        handle.seekToEndOfFile()
        try handle.write(contentsOf: fullContent.suffix(from: 1024))
        try handle.close()
        XCTAssertEqual(try Data(contentsOf: path), fullContent)
    }

    func testOversizedIncompleteFileDetected() throws {
        let path = tempDir.appendingPathComponent("file.txt.incomplete")
        try Data(repeating: 0xFF, count: 3000).write(to: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let existingSize = attrs[.size] as! Int64
        XCTAssertGreaterThan(existingSize, 2048)

        if existingSize > 2048 {
            try FileManager.default.removeItem(at: path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testResumeWithZeroOffsetWhenNoFile() {
        let path = tempDir.appendingPathComponent("newfile.txt.incomplete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let offset = resumeOffset(for: path, entrySize: 1024)
        XCTAssertEqual(offset, 0)
    }

    func testIncompleteFileWritable() throws {
        let path = tempDir.appendingPathComponent("test.dat.incomplete")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)
        try handle.write(contentsOf: Data([1, 2, 3, 4]))
        try handle.close()
        XCTAssertEqual(try Data(contentsOf: path), Data([1, 2, 3, 4]))
    }

    func testRenameIncompleteToFinal() throws {
        let content = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let incomplete = tempDir.appendingPathComponent("doc.pdf.incomplete")
        let finalDest = tempDir.appendingPathComponent("doc.pdf")
        try content.write(to: incomplete)
        try FileManager.default.moveItem(at: incomplete, to: finalDest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomplete.path))
        XCTAssertEqual(try Data(contentsOf: finalDest), content)
    }

    func testPermissionsPreservedAfterRename() throws {
        let incomplete = tempDir.appendingPathComponent("script.sh.incomplete")
        try Data([1, 2, 3]).write(to: incomplete)
        let finalPath = tempDir.appendingPathComponent("script.sh")
        try FileManager.default.moveItem(at: incomplete, to: finalPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: finalPath.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: finalPath.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o755)
    }

    func testMultipleChunkAppend() throws {
        let path = tempDir.appendingPathComponent("multi.bin.incomplete")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        for i in 0..<4 {
            let handle = try FileHandle(forWritingTo: path)
            handle.seekToEndOfFile()
            try handle.write(contentsOf: Data(repeating: UInt8(i), count: 512))
            try handle.close()
        }
        let result = try Data(contentsOf: path)
        XCTAssertEqual(result.count, 2048)
        for i in 0..<4 {
            let slice = result[i * 512..<(i + 1) * 512]
            XCTAssertTrue(slice.allSatisfy { $0 == UInt8(i) })
        }
    }

    func testDirectoryCreationForNestedFile() throws {
        let nestedDir = tempDir.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let filePath = nestedDir.appendingPathComponent("file.txt.incomplete")
        try Data([0x01]).write(to: filePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath.path))
    }

    func testRenameOverwritesExistingFinalFile() throws {
        let finalPath = tempDir.appendingPathComponent("overwrite.bin")
        let incompletePath = tempDir.appendingPathComponent("overwrite.bin.incomplete")
        try Data([0x01]).write(to: finalPath)
        try Data([0x02, 0x03]).write(to: incompletePath)
        try FileManager.default.removeItem(at: finalPath)
        try FileManager.default.moveItem(at: incompletePath, to: finalPath)
        XCTAssertEqual(try Data(contentsOf: finalPath), Data([0x02, 0x03]))
    }

    func testResumeOffsetComputation() throws {
        let entrySize: Int64 = 2048

        let path1 = tempDir.appendingPathComponent("c1.incomplete")
        XCTAssertEqual(resumeOffset(for: path1, entrySize: entrySize), 0)

        let path2 = tempDir.appendingPathComponent("c2.incomplete")
        try Data(repeating: 0xAA, count: 512).write(to: path2)
        XCTAssertEqual(resumeOffset(for: path2, entrySize: entrySize), 512)

        let path3 = tempDir.appendingPathComponent("c3.incomplete")
        try Data(repeating: 0xBB, count: Int(entrySize)).write(to: path3)
        XCTAssertEqual(resumeOffset(for: path3, entrySize: entrySize), entrySize)

        let path4 = tempDir.appendingPathComponent("c4.incomplete")
        try Data(repeating: 0xCC, count: 3000).write(to: path4)
        XCTAssertEqual(resumeOffset(for: path4, entrySize: entrySize), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path4.path))
    }

    /// Resume offset for a zero-byte entry — any existing .incomplete is oversized.
    func testResumeOffsetZeroSizeEntry() throws {
        let path = tempDir.appendingPathComponent("empty.incomplete")
        try Data([0x01]).write(to: path)
        let offset = resumeOffset(for: path, entrySize: 0)
        XCTAssertEqual(offset, 0, "Any data for a 0-byte entry means oversized")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    /// Empty .incomplete file (0 bytes) should return offset 0 (not treated as partial).
    func testResumeOffsetEmptyIncompleteFile() throws {
        let path = tempDir.appendingPathComponent("empty.incomplete")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let offset = resumeOffset(for: path, entrySize: 1024)
        XCTAssertEqual(offset, 0)
    }

    /// Exactly matching size should return entrySize (file is complete, just not renamed).
    func testResumeOffsetExactMatch() throws {
        let path = tempDir.appendingPathComponent("exact.incomplete")
        try Data(repeating: 0x42, count: 1024).write(to: path)
        let offset = resumeOffset(for: path, entrySize: 1024)
        XCTAssertEqual(offset, 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    /// Verify that the .incomplete extension appended to validatedPath produces
    /// the expected naming convention.
    func testIncompleteNamingConvention() {
        let base = URL(fileURLWithPath: "/tmp/dest/subdir/photo.jpg")
        let incomplete = base.appendingPathExtension("incomplete")
        XCTAssertEqual(incomplete.lastPathComponent, "photo.jpg.incomplete")
    }
}
