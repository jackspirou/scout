import Foundation

/// Metadata extracted from an audio file via AVAsset and its ID3 / common metadata tags.
struct AudioMetadata {
    // Technical audio properties
    let duration: TimeInterval   // seconds
    let audioCodec: String?
    let audioBitrate: Double?    // bits per second
    let sampleRate: Double?      // Hz
    let channelCount: Int?

    // ID3 / common metadata (all optional)
    let artist: String?
    let albumName: String?
    let trackTitle: String?
    let trackNumber: Int?
    let genre: String?
    let releaseYear: String?
    let composer: String?
    let albumArt: Data?          // raw image data
    let bpm: Int?
    let copyright: String?

    // Computed helpers

    /// Duration formatted as "H:MM:SS" or "M:SS".
    var formattedDuration: String { duration.formattedDuration }

    /// Channels as "Mono", "Stereo", "5.1 Surround", "7.1 Surround", or "N channels".
    var formattedChannels: String? {
        channelCount?.formattedChannelDescription
    }

    /// Sample rate as "44.1 kHz" or "48 kHz".
    var formattedSampleRate: String? {
        guard let rate = sampleRate else { return nil }
        let kHz = rate / 1000.0
        if kHz == kHz.rounded() {
            return String(format: "%.0f kHz", kHz)
        }
        return String(format: "%.1f kHz", kHz)
    }

    /// Bitrate as "256 kbps" or "1.4 Mbps".
    var formattedBitrate: String? {
        guard let bitrate = audioBitrate else { return nil }
        if bitrate >= 1_000_000 {
            let mbps = bitrate / 1_000_000.0
            if mbps == mbps.rounded() {
                return String(format: "%.0f Mbps", mbps)
            }
            return String(format: "%.1f Mbps", mbps)
        }
        let kbps = bitrate / 1000.0
        if kbps == kbps.rounded() {
            return String(format: "%.0f kbps", kbps)
        }
        return String(format: "%.1f kbps", kbps)
    }

    /// Whether any ID3-style tag metadata is present.
    var hasTagMetadata: Bool {
        artist != nil || albumName != nil || trackTitle != nil ||
        trackNumber != nil || genre != nil || releaseYear != nil ||
        composer != nil || albumArt != nil || bpm != nil ||
        copyright != nil
    }
}
