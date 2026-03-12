import AppKit

// MARK: - WaveConfig

/// Per-wave visual configuration. Groups the parameters that differ between
/// bass, mids, and treble waves, reducing parameter sprawl in `drawWave`.
private struct WaveConfig {
    let color: NSColor
    let bandStart: Int
    let bandEnd: Int
    let pointCount: Int
    let phaseOffset: CGFloat
    let harmonic: CGFloat
    let strokeAlpha: CGFloat
    let fillAlpha: CGFloat
    let mirrorStrokeAlpha: CGFloat
}

// MARK: - RealtimeWaveView

/// Renders a real-time audio visualization as smooth flowing waves driven by
/// FFT spectrum data. Three waves (bass, mids, treble) each map frequency
/// bands to control points. Mirrored around the center with gradient fills.
final class RealtimeWaveView: NSView {
    // MARK: - Properties

    /// Called when the user clicks the view. Toggles back to static waveform.
    var onTap: (() -> Void)?

    private let bandCount = kSpectrumBandCount
    private var displayValues: [Float]
    private var targetValues: [Float]
    private var lastUpdateTime: CFTimeInterval = 0

    private var animationTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    // Asymmetric smoothing — near-instant attack, fast decay for punch
    private let attackSpeed: Float = 45.0
    private let decaySpeed: Float = 10.0

    // Shared line width for all waves (uniform per professional standard)
    private let waveLineWidth: CGFloat = 1.2

    // Cached colors — rebuilt only on appearance change
    private var cachedBassColor: NSColor = .controlAccentColor
    private var cachedMidsColor: NSColor = .controlAccentColor
    private var cachedTrebleColor: NSColor = .controlAccentColor

    // Cached color space — created once
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        displayValues = Array(repeating: 0, count: kSpectrumBandCount)
        targetValues = Array(repeating: 0, count: kSpectrumBandCount)

        super.init(frame: frameRect)
        rebuildCachedColors()
        appearanceObservation = observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.rebuildCachedColors()
            self?.needsDisplay = true
        }

        lastUpdateTime = CACurrentMediaTime()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stopAnimationTimer()
    }

    // MARK: - Public API

    func pushSpectrum(_ bands: [Float]) {
        for i in 0..<min(bands.count, bandCount) {
            targetValues[i] = bands[i]
        }
    }

    func reset() {
        displayValues = Array(repeating: 0, count: bandCount)
        targetValues = Array(repeating: 0, count: bandCount)
        needsDisplay = true
    }

    // MARK: - Animation

    /// Call when the view becomes visible to start the 60fps render loop.
    func startAnimating() {
        lastUpdateTime = CACurrentMediaTime()
        startAnimationTimer()
    }

    /// Call when the view is hidden to stop wasting CPU.
    func stopAnimating() {
        stopAnimationTimer()
    }

    private func animateStep() {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastUpdateTime)
        lastUpdateTime = now
        let clampedDT = min(dt, 0.1)

        for i in 0..<bandCount {
            let current = displayValues[i]
            let target = targetValues[i]
            let speed = target > current ? attackSpeed : decaySpeed
            let factor = 1.0 - exp(-speed * clampedDT)
            displayValues[i] = current + (target - current) * factor
        }

        needsDisplay = true
    }

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.animateStep()
        }
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: - Colors

    private func rebuildCachedColors() {
        let accent = NSColor.controlAccentColor
        cachedBassColor = accent.hueRotated(by: -0.15)
        cachedMidsColor = accent
        cachedTrebleColor = accent.hueRotated(by: 0.20)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2
        let time = CGFloat(CACurrentMediaTime())

        let third = bandCount / 3

        let configs: [WaveConfig] = [
            // Bass — subtle, in the background
            WaveConfig(
                color: cachedBassColor, bandStart: 0, bandEnd: third,
                pointCount: 64, phaseOffset: 0, harmonic: 0.2,
                strokeAlpha: 0.6, fillAlpha: 0.06, mirrorStrokeAlpha: 0.35
            ),
            // Mids — medium weight
            WaveConfig(
                color: cachedMidsColor, bandStart: third, bandEnd: third * 2,
                pointCount: 64, phaseOffset: .pi * 0.5, harmonic: 0.4,
                strokeAlpha: 0.8, fillAlpha: 0.10, mirrorStrokeAlpha: 0.5
            ),
            // Treble — brightest, most prominent
            WaveConfig(
                color: cachedTrebleColor, bandStart: third * 2, bandEnd: bandCount,
                pointCount: 64, phaseOffset: .pi * 1.1, harmonic: 0.6,
                strokeAlpha: 1.0, fillAlpha: 0.15, mirrorStrokeAlpha: 0.7
            ),
        ]

        for config in configs {
            drawWave(ctx: ctx, width: width, midY: midY, time: time, config: config)
        }
    }

    private func drawWave(
        ctx: CGContext, width: CGFloat, midY: CGFloat, time: CGFloat,
        config: WaveConfig
    ) {
        let path = buildWavePath(
            width: width, midY: midY, time: time, config: config
        )

        // Gradient fill — fades from stroke color at the wave edge to
        // transparent at the center line.
        let fill = closedFillPath(from: path, midY: midY, width: width)
        ctx.saveGState()
        ctx.addPath(fill)
        ctx.clip()
        drawGradientFill(ctx: ctx, color: config.color, alpha: config.fillAlpha,
                         fromY: 0, toY: midY)
        ctx.restoreGState()

        // Stroke
        ctx.addPath(path)
        ctx.setStrokeColor(config.color.withAlphaComponent(config.strokeAlpha).cgColor)
        ctx.setLineWidth(waveLineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        // Mirror
        var mirrorXform = CGAffineTransform(translationX: 0, y: midY * 2).scaledBy(x: 1, y: -1)
        guard let mirrored = path.copy(using: &mirrorXform) else { return }

        let mirrorFill = closedFillPath(from: mirrored, midY: midY, width: width)
        ctx.saveGState()
        ctx.addPath(mirrorFill)
        ctx.clip()
        drawGradientFill(ctx: ctx, color: config.color, alpha: config.fillAlpha * 0.7,
                         fromY: midY * 2, toY: midY)
        ctx.restoreGState()

        ctx.addPath(mirrored)
        ctx.setStrokeColor(config.color.withAlphaComponent(config.mirrorStrokeAlpha).cgColor)
        ctx.setLineWidth(waveLineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// Draws a vertical gradient fill from `fromY` (colored) to `toY` (transparent).
    private func drawGradientFill(
        ctx: CGContext, color: NSColor, alpha: CGFloat,
        fromY: CGFloat, toY: CGFloat
    ) {
        let cgColor = color.withAlphaComponent(alpha).cgColor
        let clearColor = color.withAlphaComponent(0).cgColor
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [cgColor, clearColor] as CFArray,
            locations: [0, 1]
        ) else { return }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: fromY),
            end: CGPoint(x: 0, y: toY),
            options: []
        )
    }

    /// Builds a wave path from a slice of FFT bands.
    /// `pointCount` controls the number of control points — fewer points
    /// produce smoother curves (natural for bass), more points capture
    /// fine detail (natural for treble). Bands are averaged into groups
    /// when pointCount < band count.
    private func buildWavePath(
        width: CGFloat, midY: CGFloat, time: CGFloat,
        config: WaveConfig
    ) -> CGPath {
        let bandCount = config.bandEnd - config.bandStart
        guard bandCount > 0 else { return CGMutablePath() }

        let numPoints = min(config.pointCount, bandCount)
        let segmentWidth = width / CGFloat(numPoints + 1)
        var points: [CGPoint] = []

        // Global energy across this wave's band range — bleeds into every
        // point so speech (concentrated in a few bands) still moves the wave.
        var rangeEnergy: CGFloat = 0
        for i in config.bandStart..<config.bandEnd { rangeEnergy += CGFloat(displayValues[i]) }
        let avgEnergy = rangeEnergy / CGFloat(bandCount)

        // Left edge pinned to center
        points.append(CGPoint(x: 0, y: midY))

        for idx in 0..<numPoints {
            let x = segmentWidth * CGFloat(idx + 1)
            let t = CGFloat(idx) / CGFloat(max(1, numPoints - 1))

            // Max magnitude across bands that map to this control point.
            // Using max (not average) preserves narrow spectral peaks that
            // averaging would suppress — recommended by dlbeer, used by
            // audioMotion-analyzer.
            let groupStart = config.bandStart + idx * bandCount / numPoints
            let groupEnd = config.bandStart + (idx + 1) * bandCount / numPoints
            var groupAmp: CGFloat = 0
            for i in groupStart..<groupEnd {
                let v = CGFloat(displayValues[i])
                if v > groupAmp { groupAmp = v }
            }

            // 90% local band, 10% range average for minimal spatial coherence
            let amp = min(1.0, groupAmp * 0.9 + avgEnergy * 0.1)

            // Time-based oscillation for organic motion. Wobble intensity
            // scales inversely with amplitude: during silence, a gentle
            // breathing animation keeps the visualizer alive; during loud
            // passages, the FFT data drives the motion directly.
            let wobbleRaw = sin(t * .pi * 2 + time * 2.0 + config.phaseOffset)
                          + sin(t * .pi * 3.5 + time * 1.4) * config.harmonic
                          + sin(t * .pi * 5.0 + time * 3.2 + config.phaseOffset * 0.5) * 0.3
            let wobbleScale = 0.05 + 0.20 * (1.0 - amp)
            let wobble = wobbleRaw * wobbleScale

            // Idle breathing — subtle baseline displacement when silent
            let breath = (1.0 - amp) * 0.03 * sin(time * 0.8 + t * .pi + config.phaseOffset)

            let displacement = amp + breath + amp * wobble
            let y = midY - displacement * midY * 0.95

            points.append(CGPoint(x: x, y: y))
        }

        // Right edge pinned to center
        points.append(CGPoint(x: width, y: midY))

        return catmullRomPath(through: points)
    }

    /// Converts an array of points into a smooth Catmull-Rom spline CGPath.
    private func catmullRomPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])

        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[min(points.count - 1, i + 1)]
            let p3 = points[min(points.count - 1, i + 2)]

            let cp1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let cp2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return path
    }

    /// Closes a wave path down to the center line for filling.
    private func closedFillPath(from wavePath: CGPath, midY: CGFloat, width: CGFloat) -> CGPath {
        let fill = CGMutablePath()
        fill.addPath(wavePath)
        fill.addLine(to: CGPoint(x: width, y: midY))
        fill.addLine(to: CGPoint(x: 0, y: midY))
        fill.closeSubpath()
        return fill
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }
}

// MARK: - NSColor Hue Rotation

private extension NSColor {
    /// Returns a new color with the hue shifted by the given amount (0...1 wraps).
    func hueRotated(by amount: CGFloat) -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newHue = (h + amount).truncatingRemainder(dividingBy: 1.0)
        return NSColor(hue: newHue < 0 ? newHue + 1 : newHue, saturation: s, brightness: b, alpha: a)
    }
}
