import Foundation
import Network

// MARK: - ScoutDropFramer

/// NWProtocolFramer implementation for the ScoutDrop binary wire protocol.
/// Handles message framing with a 9-byte binary header, JSON metadata, and raw binary payloads.
final class ScoutDropFramer: NWProtocolFramerImplementation {
    static let label = "ScoutDrop"
    static let definition = NWProtocolFramer.Definition(implementation: ScoutDropFramer.self)

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            // Try to parse a complete message.
            var tempHeader = ScoutDropFrameHeader()
            let headerSize = ScoutDropFrameHeader.encodedSize

            let parsed = framer.parseInput(
                minimumIncompleteLength: headerSize,
                maximumLength: headerSize
            ) { buffer, _ in
                guard let buffer, buffer.count >= headerSize else { return 0 }
                tempHeader = ScoutDropFrameHeader(UnsafeRawBufferPointer(buffer))
                return headerSize
            }

            guard parsed, tempHeader.messageType != 0 else { return headerSize }

            let totalBodyLength = Int(tempHeader.metadataLength) + Int(tempHeader.payloadLength)

            // Reject unreasonably large frames to prevent memory exhaustion.
            let maxFrameBodySize = 16_777_216  // 16 MB
            guard totalBodyLength <= maxFrameBodySize else {
                return 0
            }

            // Create an NWProtocolFramer.Message with the header info.
            let message = NWProtocolFramer.Message(definition: Self.definition)
            message.scoutDropHeader = tempHeader

            // Deliver the combined metadata+payload body as the message content.
            guard framer.deliverInputNoCopy(
                length: totalBodyLength,
                message: message,
                isComplete: true
            ) else {
                return 0
            }
        }
    }

    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        guard let header = message.scoutDropHeader else { return }

        // Write the 9-byte binary header.
        header.encode().withUnsafeBytes { buffer in
            framer.writeOutput(data: buffer)
        }

        // Forward the body (metadata JSON + payload binary) written by the caller.
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            NSLog("[ScoutDropFramer] writeOutputNoCopy failed: %@", error.localizedDescription)
        }
    }
}

// MARK: - ScoutDropFrameHeader

struct ScoutDropFrameHeader {
    static let encodedSize = 9

    var messageType: UInt8 = 0
    var metadataLength: UInt32 = 0
    var payloadLength: UInt32 = 0

    init() {}

    init(_ buffer: UnsafeRawBufferPointer) {
        messageType = buffer.load(fromByteOffset: 0, as: UInt8.self)
        metadataLength = buffer.loadUnaligned(fromByteOffset: 1, as: UInt32.self).bigEndian
        payloadLength = buffer.loadUnaligned(fromByteOffset: 5, as: UInt32.self).bigEndian
    }

    func encode() -> Data {
        var data = Data(count: Self.encodedSize)
        data[0] = messageType
        var metaBE = metadataLength.bigEndian
        var payBE = payloadLength.bigEndian
        data.replaceSubrange(1..<5, with: Data(bytes: &metaBE, count: 4))
        data.replaceSubrange(5..<9, with: Data(bytes: &payBE, count: 4))
        return data
    }
}

// MARK: - ScoutDropFrameHeader Message Type Constants

extension ScoutDropFrameHeader {
    // Control stream message types (JSON metadata).
    static let typeOffer: UInt8 = 0x01
    static let typeAccept: UInt8 = 0x02
    static let typeDecline: UInt8 = 0x03
    static let typeComplete: UInt8 = 0x06
    static let typeError: UInt8 = 0x07

    // File stream message types (compact binary, no JSON).
    static let typeFileStart: UInt8 = 0x08  // 2-byte metadata (fileIndex UInt16 BE) + payload
    static let typeFileData: UInt8 = 0x09   // 0-byte metadata, raw payload
    static let typeFileEnd: UInt8 = 0x0A    // SHA-256 hex metadata, final payload (may be empty)

    // Extended control message types.
    static let typeFileError: UInt8 = 0x0B  // Per-file error: JSON metadata with fileIndex + error
    static let typeHeartbeat: UInt8 = 0x0C  // Keepalive: 0-byte metadata, 0-byte payload
}

// MARK: - NWProtocolFramer.Message Extension

extension NWProtocolFramer.Message {
    private static let headerKey = "ScoutDropHeader"

    var scoutDropHeader: ScoutDropFrameHeader? {
        get { self[Self.headerKey] as? ScoutDropFrameHeader }
        set { self[Self.headerKey] = newValue }
    }
}
