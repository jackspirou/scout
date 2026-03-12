import Foundation

/// Metadata extracted from a video or audio file via AVAsset.
struct VideoMetadata {
    // Video track (nil for audio-only files)
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let videoCodec: String?
    let videoBitrate: Double?    // bits per second

    // Audio track (nil for silent video)
    let audioCodec: String?
    let audioBitrate: Double?    // bits per second
    let sampleRate: Double?      // Hz
    let channelCount: Int?

    // Container
    let duration: TimeInterval   // seconds
    let totalBitrate: Double?    // bits per second

    // Computed helpers

    /// Whether the file has a video track.
    var hasVideo: Bool { width != nil && height != nil }

    /// Whether the file has an audio track.
    var hasAudio: Bool { audioCodec != nil }

    /// Duration formatted as "H:MM:SS" or "M:SS".
    var formattedDuration: String {
        let total = Int(round(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Resolution as "1920 x 1080".
    var formattedResolution: String? {
        guard let w = width, let h = height else { return nil }
        return "\(w) \u{00D7} \(h)"
    }

    /// Aspect ratio as "W:H" in simplified form.
    var aspectRatio: String? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        let g = gcd(w, h)
        let rw = w / g
        let rh = h / g
        if rw > 50 || rh > 50 {
            let ratio = Double(w) / Double(h)
            return String(format: "%.2f:1", ratio)
        }
        return "\(rw):\(rh)"
    }

    /// Channels as "Mono", "Stereo", or "N channels".
    var formattedChannels: String? {
        guard let count = channelCount else { return nil }
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1 Surround"
        case 8: return "7.1 Surround"
        default: return "\(count) channels"
        }
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}
