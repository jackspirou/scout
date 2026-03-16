import AppKit
import AVFoundation

// MARK: - WaveformData

/// Downsampled audio waveform data ready for rendering.
/// Each sample represents a time bucket with min/max amplitude values.
struct WaveformData {
    /// Normalized amplitude pairs (min, max) in range [-1, 1].
    let samples: [(min: Float, max: Float)]
    let duration: TimeInterval
}

// MARK: - WaveformView

/// Renders an audio waveform and tracks playback position.
/// Supports click-to-seek and visual playhead tracking.
final class WaveformView: NSView {
    // MARK: - Properties

    /// The waveform data to render.
    var waveformData: WaveformData? { didSet { needsDisplay = true } }

    /// Current playback progress in [0, 1].
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    /// Called when the user clicks to seek. Parameter is normalized position [0, 1].
    var onSeek: ((Double) -> Void)?

    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearanceObservation = observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let data = waveformData, !data.samples.isEmpty else {
            drawPlaceholder(in: bounds)
            return
        }

        let context = NSGraphicsContext.current!.cgContext
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2
        let sampleCount = data.samples.count

        // Draw waveform bars
        let playedColor = NSColor.controlAccentColor.cgColor
        let unplayedColor = NSColor.secondaryLabelColor.withAlphaComponent(0.3).cgColor
        let playedIndex = Int(progress * CGFloat(sampleCount))

        for i in 0..<Int(width) {
            let sampleIndex = Int(Double(i) / Double(width) * Double(sampleCount))
            guard sampleIndex < sampleCount else { continue }

            let sample = data.samples[sampleIndex]
            let minY = midY + CGFloat(sample.min) * midY
            let maxY = midY + CGFloat(sample.max) * midY

            context.setFillColor(sampleIndex <= playedIndex ? playedColor : unplayedColor)
            let barRect = CGRect(x: CGFloat(i), y: minY, width: 1, height: max(maxY - minY, 1))
            context.fill(barRect)
        }

        // Draw playhead line
        if progress > 0, progress < 1 {
            let x = progress * width
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
            context.strokePath()
        }
    }

    private func drawPlaceholder(in rect: NSRect) {
        let context = NSGraphicsContext.current!.cgContext
        let midY = rect.height / 2

        // Draw a thin center line
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: rect.minX, y: midY))
        context.addLine(to: CGPoint(x: rect.maxX, y: midY))
        context.strokePath()
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        seek(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        seek(with: event)
    }

    private func seek(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let normalized = max(0, min(1, Double(location.x / bounds.width)))
        onSeek?(normalized)
    }

    // MARK: - Static Waveform Generation

    /// Generates waveform data from an audio file URL.
    /// Runs entirely off the main thread. Returns nil if the file
    /// cannot be read or has no audio track.
    static func generateWaveform(from url: URL, targetSampleCount: Int = 2048) async -> WaveformData? {
        let asset = AVURLAsset(url: url)

        do {
            let durationCM = try await asset.load(.duration)
            let duration = CMTimeGetSeconds(durationCM)
            guard duration.isFinite, duration > 0 else { return nil }

            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { return nil }

            return await Task.detached {
                readAndDownsample(asset: asset, track: track, duration: duration,
                                  targetSampleCount: targetSampleCount)
            }.value
        } catch {
            return nil
        }
    }

    /// Reads PCM samples from a track and downsamples in a single streaming pass.
    /// Uses an estimated total sample count from duration to size buckets, avoiding
    /// loading the entire file into memory.
    private nonisolated static func readAndDownsample(
        asset: AVURLAsset, track: AVAssetTrack,
        duration: TimeInterval, targetSampleCount: Int
    ) -> WaveformData? {
        // Configure reader to output PCM float samples
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        guard let reader = try? AVAssetReader(asset: asset)
        else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)

        reader.add(output)
        guard reader.startReading() else { return nil }

        // Estimate total samples from duration. Assume 44.1kHz stereo as default.
        // The exact count doesn't matter — we'll clamp bucket indices to bounds.
        let estimatedSampleRate = 44100.0
        let estimatedChannels = 2.0
        let estimatedTotal = Int(duration * estimatedSampleRate * estimatedChannels)
        let samplesPerBucket = max(1, estimatedTotal / targetSampleCount)
        let bucketCount = targetSampleCount

        var result: [(min: Float, max: Float)] = Array(repeating: (min: 0, max: 0), count: bucketCount)
        var sampleIndex = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer)

            guard let pointer = dataPointer else { continue }

            let floatCount = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPointer in
                for j in 0..<floatCount {
                    let bucketIndex = min(sampleIndex / samplesPerBucket, bucketCount - 1)
                    let val = floatPointer[j]
                    if val < result[bucketIndex].min { result[bucketIndex].min = val }
                    if val > result[bucketIndex].max { result[bucketIndex].max = val }
                    sampleIndex += 1
                }
            }
        }

        guard sampleIndex > 0 else { return nil }

        // Trim unused buckets if file was shorter than estimated
        let usedBuckets = min(bucketCount, (sampleIndex / samplesPerBucket) + 1)
        return WaveformData(samples: Array(result.prefix(usedBuckets)), duration: duration)
    }
}
