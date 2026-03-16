import Accelerate
import AVFoundation
import MediaToolbox

// MARK: - Constants

/// Number of frequency bands for the spectrum visualization.
/// 96 bands — 32 per wave (bass/mids/treble) for high-fidelity curves.
let kSpectrumBandCount = 96

/// FFT window size. Must be a power of 2.
/// 1024 gives good frequency resolution at typical sample rates.
private let kFFTSize = 1024

/// Decibel floor — anything below is treated as silence.
/// Narrower range (-50 to -5) maps typical music dynamics to the full 0...1 range.
private let kMinDB: Float = -40

/// Decibel ceiling — clips at this level.
private let kMaxDB: Float = -3

// MARK: - TapContext

/// Mutable state shared between the tap callbacks and the owning AudioLevelTap.
/// Pre-allocates all FFT buffers so the realtime audio thread never allocates.
private final class TapContext {
    var onSpectrum: (([Float]) -> Void)?

    // FFT setup (created once, destroyed in deinit)
    let log2n: vDSP_Length
    let fftSetup: FFTSetup
    let halfSize: Int

    // Pre-allocated buffers (no allocations on the audio thread)
    var window: [Float]
    var windowedSamples: [Float]
    var realPart: [Float]
    var imagPart: [Float]
    var magnitudes: [Float]
    var bandResult: [Float]

    /// Frequency band bin ranges (logarithmically spaced)
    var bands: [(low: Int, high: Int)]

    init() {
        let n = kFFTSize
        halfSize = n / 2
        log2n = vDSP_Length(log2(Double(n)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // Hanning window reduces spectral leakage
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        windowedSamples = [Float](repeating: 0, count: n)
        realPart = [Float](repeating: 0, count: n / 2)
        imagPart = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)
        bandResult = [Float](repeating: 0, count: kSpectrumBandCount)

        // Default bands for 44100 Hz — recomputed in prepare if sample rate differs
        bands = Self.logarithmicBands(
            count: kSpectrumBandCount, fftSize: n, sampleRate: 44100
        )
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Recomputes frequency band edges for the actual sample rate.
    func updateSampleRate(_ sampleRate: Double) {
        bands = Self.logarithmicBands(
            count: kSpectrumBandCount, fftSize: kFFTSize, sampleRate: Float(sampleRate)
        )
    }

    /// Creates logarithmically spaced frequency band bin ranges.
    /// Human pitch perception is logarithmic, so this ensures bass, mids,
    /// and treble each get roughly equal visual representation.
    static func logarithmicBands(
        count: Int, fftSize: Int, sampleRate: Float
    ) -> [(low: Int, high: Int)] {
        let minFreq: Float = 80 // skip sub-bass rumble
        let maxFreq: Float = 16000 // skip inaudible ultrasonic
        let maxBin = fftSize / 2 - 1

        var result: [(low: Int, high: Int)] = []
        for i in 0 ..< count {
            let lowFreq = minFreq * pow(maxFreq / minFreq, Float(i) / Float(count))
            let highFreq = minFreq * pow(maxFreq / minFreq, Float(i + 1) / Float(count))
            let lowBin = min(maxBin, max(1, Int(lowFreq * Float(fftSize) / sampleRate)))
            let highBin = min(maxBin, max(lowBin, Int(highFreq * Float(fftSize) / sampleRate)))
            result.append((low: lowBin, high: highBin))
        }
        return result
    }
}

// MARK: - AudioLevelTap

/// Wraps an `MTAudioProcessingTap` to perform real-time FFT spectrum analysis
/// on an `AVPlayerItem` during playback. Delivers per-frequency-band magnitudes
/// to the main thread via `onSpectrum`.
final class AudioLevelTap {
    // MARK: - Properties

    /// Called on the main thread with normalized magnitudes per frequency band (0...1).
    /// Array length is `kSpectrumBandCount`.
    var onSpectrum: (([Float]) -> Void)?

    private var tap: MTAudioProcessingTap?
    private weak var playerItem: AVPlayerItem?

    // MARK: - Lifecycle

    deinit {
        remove()
    }

    // MARK: - Public API

    /// Installs an audio processing tap on the given player item.
    /// The tap performs FFT spectrum analysis and delivers band magnitudes via `onSpectrum`.
    /// If the player item has no audio track or tap creation fails,
    /// this method returns silently.
    @MainActor func install(on playerItem: AVPlayerItem) async {
        remove()

        guard let audioTrack = try? await playerItem.asset.loadTracks(withMediaType: .audio).first
        else { return }

        let context = TapContext()
        context.onSpectrum = onSpectrum

        let contextPointer = Unmanaged.passRetained(context).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: contextPointer,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )

        #if compiler(>=6.2)
            var tapRef: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(
                kCFAllocatorDefault,
                &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects,
                &tapRef
            )
            guard status == noErr, let tapValue = tapRef else {
                Unmanaged<TapContext>.fromOpaque(contextPointer).release()
                return
            }
        #else
            var unmanagedTap: Unmanaged<MTAudioProcessingTap>?
            let status = MTAudioProcessingTapCreate(
                kCFAllocatorDefault,
                &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects,
                &unmanagedTap
            )
            guard status == noErr, let tapValue = unmanagedTap?.takeRetainedValue() else {
                Unmanaged<TapContext>.fromOpaque(contextPointer).release()
                return
            }
        #endif

        let params = AVMutableAudioMixInputParameters(track: audioTrack)
        params.audioTapProcessor = tapValue

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [params]

        playerItem.audioMix = audioMix

        tap = tapValue
        self.playerItem = playerItem
    }

    /// Removes the audio processing tap from the player item.
    /// Safe to call multiple times.
    func remove() {
        playerItem?.audioMix = nil
        playerItem = nil
        tap = nil
    }
}

// MARK: - Tap Callbacks

/// Called when the tap is initialized. Stores the context pointer in tapStorage.
private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

/// Called when the tap is finalized. Releases the retained TapContext.
private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<TapContext>.fromOpaque(storage).release()
}

/// Called when the tap is prepared. Captures the actual sample rate for accurate
/// frequency band mapping.
private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
    let format = processingFormat.pointee
    if format.mSampleRate > 0 {
        context.updateSampleRate(format.mSampleRate)
    }
}

/// Called when the tap is unprepared. No-op.
private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

/// Called on the realtime audio thread for each audio buffer.
/// Performs FFT, groups magnitudes into logarithmic frequency bands,
/// converts to dB, normalizes, and dispatches to main thread.
private let tapProcess: MTAudioProcessingTapProcessCallback = {
    tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
    )
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()

    // Get samples from the first audio channel
    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    guard let firstBuffer = bufferList.first, let data = firstBuffer.mData else { return }
    let sampleCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
    guard sampleCount > 0 else { return }

    let samples = data.assumingMemoryBound(to: Float.self)
    let n = min(sampleCount, kFFTSize)

    // Apply Hanning window to reduce spectral leakage
    vDSP_vmul(samples, 1, context.window, 1, &context.windowedSamples, 1, vDSP_Length(n))

    // Zero-pad if buffer is smaller than FFT size
    if n < kFFTSize {
        for i in n ..< kFFTSize {
            context.windowedSamples[i] = 0
        }
    }

    // Pack into split complex format and run forward FFT
    context.windowedSamples.withUnsafeBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: context.halfSize) { complexPtr in
            context.realPart.withUnsafeMutableBufferPointer { realBuf in
                context.imagPart.withUnsafeMutableBufferPointer { imagBuf in
                    var splitComplex = DSPSplitComplex(
                        realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!
                    )
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(context.halfSize))
                    vDSP_fft_zrip(context.fftSetup, &splitComplex, 1, context.log2n, FFTDirection(FFT_FORWARD))

                    // Compute magnitudes: sqrt(real^2 + imag^2)
                    vDSP_zvabs(&splitComplex, 1, &context.magnitudes, 1, vDSP_Length(context.halfSize))
                }
            }
        }
    }

    // Normalize magnitudes by FFT size
    var scale = 1.0 / Float(kFFTSize)
    vDSP_vsmul(context.magnitudes, 1, &scale, &context.magnitudes, 1, vDSP_Length(context.halfSize))

    // Group into logarithmic frequency bands using max magnitude per band,
    // apply spectral tilt compensation, convert to dB, and normalize to 0...1.
    let dbRange = kMaxDB - kMinDB
    for i in 0 ..< kSpectrumBandCount {
        let band = context.bands[i]
        var maxMag: Float = 0
        let lo = min(band.low, context.halfSize - 1)
        let hi = min(band.high, context.halfSize - 1)
        guard lo <= hi else { continue }
        for bin in lo ... hi {
            if context.magnitudes[bin] > maxMag {
                maxMag = context.magnitudes[bin]
            }
        }

        // Spectral tilt compensation (+3 dB/octave). Natural audio follows
        // a pink noise spectrum (~-3 dB/octave), so higher frequencies have
        // inherently less energy. Professional spectrum analyzers apply a
        // rising slope to compensate, giving equal visual weight across the
        // spectrum. The tilt is computed as the band's center bin relative
        // to the lowest bin (band 0), measured in octaves.
        let centerBin = Float(lo + hi) / 2.0
        let refBin = max(Float(context.bands[0].low), 1.0)
        let octaves = log2f(max(centerBin / refBin, 1.0))
        let tiltDB: Float = 3.0 * octaves
        let tiltLinear = powf(10.0, tiltDB / 20.0)
        let compensated = maxMag * tiltLinear

        let db = 20 * log10f(max(compensated, 1e-7))
        let linear = max(0, min(1, (db - kMinDB) / dbRange))
        // Compressive power curve (gamma 0.6) — expands quiet signals so
        // speech and subtle high-frequency content are visible, while
        // preserving contrast for loud peaks.
        context.bandResult[i] = powf(linear, 0.6)
    }

    // Dispatch band magnitudes to main thread
    let result = Array(context.bandResult)
    let callback = context.onSpectrum
    DispatchQueue.main.async {
        callback?(result)
    }
}
