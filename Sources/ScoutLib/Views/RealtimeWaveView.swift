import AppKit
import CoreVideo

// MARK: - RealtimeWaveView

/// Renders a real-time audio visualization as smooth flowing waves driven by
/// FFT spectrum data. A primary wave maps each frequency band directly to a
/// control point, so spectral spikes (kicks, snares, vocals) create visible
/// peaks. A thinner echo wave adds depth. Both are mirrored around the center.
///
/// Uses CVDisplayLink for jitter-free, display-synced animation.
final class RealtimeWaveView: NSView {
    // MARK: - Properties

    /// Called when the user clicks the view. Toggles back to static waveform.
    var onTap: (() -> Void)?

    private let bandCount = kSpectrumBandCount
    private var displayValues: [Float]
    private var targetValues: [Float]
    private var lastUpdateTime: CFTimeInterval = 0

    private var displayLink: CVDisplayLink?
    private var isDecaying = false
    private var appearanceObservation: NSKeyValueObservation?

    // Asymmetric smoothing — near-instant attack, fast decay for punch
    private let attackSpeed: Float = 45.0
    private let decaySpeed: Float = 10.0

    // Cached colors — recomputed on appearance change to avoid per-frame
    // color space conversions in draw().
    private var cachedBassColor: NSColor = .controlAccentColor
    private var cachedMidsColor: NSColor = .controlAccentColor
    private var cachedTrebleColor: NSColor = .controlAccentColor
    private var cachedCenterLineColor: NSColor = .controlAccentColor

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        displayValues = Array(repeating: 0, count: kSpectrumBandCount)
        targetValues = Array(repeating: 0, count: kSpectrumBandCount)

        super.init(frame: frameRect)
        updateCachedColors()
        appearanceObservation = observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.updateCachedColors()
            self?.needsDisplay = true
        }

        lastUpdateTime = CACurrentMediaTime()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Public API

    func pushSpectrum(_ bands: [Float]) {
        // Ignore incoming FFT data while decaying — queued audio tap callbacks
        // arrive after pause and would fight the smooth decay to rest.
        guard !isDecaying else { return }
        for i in 0 ..< min(bands.count, bandCount) {
            targetValues[i] = bands[i]
        }
    }

    func reset() {
        stopDisplayLink()
        isDecaying = false
        displayValues = Array(repeating: 0, count: bandCount)
        targetValues = Array(repeating: 0, count: bandCount)
        needsDisplay = true
    }

    // MARK: - Display Link

    func startAnimating() {
        guard displayLink == nil else { return }
        isDecaying = false
        lastUpdateTime = CACurrentMediaTime()

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let view = Unmanaged<RealtimeWaveView>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { view.animateStep() }
            return kCVReturnSuccess
        }

        let pointer = Unmanaged.passRetained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, callback, pointer)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    func stopAnimating() {
        // Zero out targets so waves decay to rest, but keep the display link
        // running until values settle. The link self-stops in animateStep().
        for i in 0 ..< bandCount {
            targetValues[i] = 0
        }
        isDecaying = true
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            // Release the retained self that was passed to the display link callback.
            Unmanaged<RealtimeWaveView>.passUnretained(self).release()
            displayLink = nil
        }
    }

    // MARK: - Animation

    private func animateStep() {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastUpdateTime)
        lastUpdateTime = now
        let clampedDT = min(dt, 0.1)

        var maxValue: Float = 0
        for i in 0 ..< bandCount {
            let current = displayValues[i]
            let target = targetValues[i]
            let speed = target > current ? attackSpeed : decaySpeed
            let factor = 1.0 - exp(-speed * clampedDT)
            let newValue = current + (target - current) * factor
            displayValues[i] = newValue
            maxValue = max(maxValue, abs(newValue))
        }

        needsDisplay = true

        // Once decaying and all values have settled near zero, stop.
        if isDecaying, maxValue < 0.001 {
            for i in 0 ..< bandCount {
                displayValues[i] = 0
            }
            stopDisplayLink()
            isDecaying = false
            needsDisplay = true
        }
    }

    // MARK: - Colors

    private func updateCachedColors() {
        let accent = NSColor.controlAccentColor
        cachedBassColor = accent.hueRotated(by: 0.12)
        cachedMidsColor = accent
        cachedTrebleColor = accent.hueRotated(by: -0.08)
        cachedCenterLineColor = accent.withAlphaComponent(0.12)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2
        let time = CGFloat(CACurrentMediaTime())

        let third = bandCount / 3

        // Bass wave — heaviest and bright, drawn first (behind)
        drawWave(
            ctx: ctx, width: width, midY: midY, time: time, color: cachedBassColor,
            bandStart: 0, bandEnd: third, gain: 1.0,
            phaseOffset: 0, harmonic: 0.2, strokeAlpha: 0.85, fillAlpha: 0.06,
            lineWidth: 3.5, mirrorStrokeAlpha: 0.5, mirrorLineWidth: 2.8
        )

        // Treble wave — warm/coral, thinner line
        drawWave(
            ctx: ctx, width: width, midY: midY, time: time, color: cachedTrebleColor,
            bandStart: third * 2, bandEnd: bandCount, gain: 1.0,
            phaseOffset: .pi * 1.1, harmonic: 0.6, strokeAlpha: 1.0, fillAlpha: 0.08,
            lineWidth: 0.8, mirrorStrokeAlpha: 0.7, mirrorLineWidth: 0.6
        )

        // Mids wave — accent blue (same as timeline), bright and bold, drawn last (on top)
        drawWave(
            ctx: ctx, width: width, midY: midY, time: time, color: cachedMidsColor,
            bandStart: third, bandEnd: third * 2, gain: 1.0,
            phaseOffset: .pi * 0.5, harmonic: 0.4, strokeAlpha: 1.0, fillAlpha: 0.07,
            lineWidth: 2.4, mirrorStrokeAlpha: 0.7, mirrorLineWidth: 2.0
        )

        // Center line
        ctx.setStrokeColor(cachedCenterLineColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0, y: midY))
        ctx.addLine(to: CGPoint(x: width, y: midY))
        ctx.strokePath()
    }

    private func drawWave(
        ctx: CGContext, width: CGFloat, midY: CGFloat, time: CGFloat,
        color: NSColor, bandStart: Int, bandEnd: Int, gain: CGFloat,
        phaseOffset: CGFloat, harmonic: CGFloat,
        strokeAlpha: CGFloat, fillAlpha: CGFloat, lineWidth: CGFloat,
        mirrorStrokeAlpha: CGFloat, mirrorLineWidth: CGFloat
    ) {
        let path = buildWavePath(
            width: width, midY: midY, time: time,
            bandStart: bandStart, bandEnd: bandEnd, gain: gain,
            phaseOffset: phaseOffset, harmonic: harmonic
        )

        // Fill
        let fill = closedFillPath(from: path, midY: midY, width: width)
        ctx.saveGState()
        ctx.addPath(fill)
        ctx.setFillColor(color.withAlphaComponent(fillAlpha).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Stroke
        ctx.addPath(path)
        ctx.setStrokeColor(color.withAlphaComponent(strokeAlpha).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        // Mirror
        var mirrorXform = CGAffineTransform(translationX: 0, y: midY * 2).scaledBy(x: 1, y: -1)
        guard let mirrored = path.copy(using: &mirrorXform) else { return }

        let mirrorFill = closedFillPath(from: mirrored, midY: midY, width: width)
        ctx.saveGState()
        ctx.addPath(mirrorFill)
        ctx.setFillColor(color.withAlphaComponent(fillAlpha * 0.7).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(mirrored)
        ctx.setStrokeColor(color.withAlphaComponent(mirrorStrokeAlpha).cgColor)
        ctx.setLineWidth(mirrorLineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// Builds a wave path from a slice of FFT bands.
    /// Each band in the range becomes a control point spread across the full width.
    private func buildWavePath(
        width: CGFloat, midY: CGFloat, time: CGFloat,
        bandStart: Int, bandEnd: Int, gain: CGFloat,
        phaseOffset: CGFloat, harmonic: CGFloat
    ) -> CGPath {
        let count = bandEnd - bandStart
        guard count > 0 else { return CGMutablePath() }

        let segmentWidth = width / CGFloat(count + 1)
        var points: [CGPoint] = []

        // Global energy across this wave's band range — bleeds into every
        // point so speech (concentrated in a few bands) still moves the wave.
        var rangeEnergy: CGFloat = 0
        for i in bandStart ..< bandEnd {
            rangeEnergy += CGFloat(displayValues[i])
        }
        let avgEnergy = rangeEnergy / CGFloat(count)

        // Left edge pinned to center
        points.append(CGPoint(x: 0, y: midY))

        for idx in 0 ..< count {
            let i = bandStart + idx
            let x = segmentWidth * CGFloat(idx + 1)
            let t = CGFloat(idx) / CGFloat(max(1, count - 1))
            let bandAmp = CGFloat(displayValues[i])

            // 70% local band, 30% range average, then apply gain and clamp
            let amp = min(1.0, (bandAmp * 0.7 + avgEnergy * 0.3) * gain)

            // Time-based oscillation for organic motion
            let wobble = sin(t * .pi * 2 + time * 2.0 + phaseOffset)
                + sin(t * .pi * 3.5 + time * 1.4) * harmonic
                + sin(t * .pi * 5.0 + time * 3.2 + phaseOffset * 0.5) * 0.3

            let displacement = amp * (1.0 + wobble * 0.25)
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

        for i in 0 ..< (points.count - 1) {
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
