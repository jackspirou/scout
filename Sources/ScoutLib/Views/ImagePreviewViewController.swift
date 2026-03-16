import AppKit
import Highlighter

// MARK: - ImagePreviewViewController

/// Displays an image file with a collapsible metadata header, media info section,
/// and zoomable/pannable image canvas.
/// Supports zoom (pinch, scroll-wheel, double-click) and drag-to-pan.
/// For SVG files, supports a Code/Preview toggle to view raw SVG source.
final class ImagePreviewViewController: NSViewController, PreviewChild {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()
    private let mediaInfoView = MediaInfoView()
    private var scrollView: NSScrollView!
    private var imageCanvas: ImageCanvasView!
    private var currentItem: FileItem?
    private var currentLoadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var appearanceObservation: NSKeyValueObservation?

    // SVG code view
    private var codeScrollView: NSScrollView!
    private var codeTextView: NSTextView!
    private var codeRulerView: LineNumberRulerView!
    private var highlighter: Highlighter?
    private var isCodeMode = false

    private var imagePixelSize: NSSize = .zero
    private var isCentering = false
    private var lastVisibleSize: NSSize = .zero

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configureScrollView()
        configureCodeView()

        // MediaInfoView starts hidden — shown once metadata loads.
        mediaInfoView.isHidden = true

        view.addSubview(headerView)
        view.addSubview(mediaInfoView)

        layoutSubviews()

        highlighter = Highlighter()

        headerView.onModeChanged = { [weak self] segment in
            self?.setSVGMode(segment)
        }

        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.headerView.updateAppearance()
            self?.mediaInfoView.updateAppearance()
            self?.updateHighlighterTheme()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard imagePixelSize.width > 0 else { return }

        // Use the scroll view's frame (not contentView.bounds) to detect
        // visible area changes. bounds.size changes with magnification and
        // creates a feedback loop during live resize; frame.size does not.
        let frameSize = scrollView.frame.size
        if frameSize != lastVisibleSize {
            lastVisibleSize = frameSize
            applyFitMagnification()
        }
        centerImageIfNeeded()
    }

    // MARK: - Configuration

    private func configureScrollView() {
        let clipView = CenteringClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = .textBackgroundColor

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clipView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 10.0

        imageCanvas = ImageCanvasView()
        imageCanvas.onDoubleClick = { [weak self] in self?.toggleFitActualSize() }
        scrollView.documentView = imageCanvas

        NotificationCenter.default.addObserver(
            self, selector: #selector(magnificationDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
        )

        view.addSubview(scrollView)
    }

    private func configureCodeView() {
        codeScrollView = NSScrollView()
        codeScrollView.translatesAutoresizingMaskIntoConstraints = false
        codeScrollView.hasVerticalScroller = true
        codeScrollView.autohidesScrollers = true
        codeScrollView.drawsBackground = true
        codeScrollView.backgroundColor = .textBackgroundColor
        codeScrollView.isHidden = true

        codeTextView = NSTextView()
        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.usesFindBar = true
        codeTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        codeTextView.textColor = .labelColor
        codeTextView.drawsBackground = false
        codeTextView.isVerticallyResizable = true
        codeTextView.isHorizontallyResizable = false
        codeTextView.autoresizingMask = [.width]
        codeTextView.textContainer?.widthTracksTextView = true
        codeTextView.textContainerInset = NSSize(width: 4, height: 8)

        codeScrollView.documentView = codeTextView
        codeRulerView = LineNumberRulerView(textView: codeTextView, scrollView: codeScrollView)
        codeRulerView.isHidden = true

        view.addSubview(codeRulerView)
        view.addSubview(codeScrollView)
    }

    private func layoutSubviews() {
        let rulerWidthConstraint = codeRulerView.widthAnchor.constraint(equalToConstant: codeRulerView.gutterWidth)
        codeRulerView.setWidthConstraint(rulerWidthConstraint)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            mediaInfoView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 1),
            mediaInfoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mediaInfoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: mediaInfoView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            codeRulerView.topAnchor.constraint(equalTo: mediaInfoView.bottomAnchor),
            codeRulerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            codeRulerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rulerWidthConstraint,

            codeScrollView.topAnchor.constraint(equalTo: mediaInfoView.bottomAnchor),
            codeScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            codeScrollView.leadingAnchor.constraint(equalTo: codeRulerView.trailingAnchor),
            codeScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Public API

    func displayItem(_ item: FileItem) {
        currentLoadTask?.cancel()
        metadataTask?.cancel()
        currentItem = item
        imagePixelSize = .zero
        mediaInfoView.isHidden = true
        isCodeMode = false

        headerView.update(with: item)
        headerView.setMarkdownMode(item.isSVG)

        // Reset to preview mode
        scrollView.isHidden = false
        codeScrollView.isHidden = true
        codeRulerView.isHidden = true

        currentLoadTask = Task { [weak self] in
            await self?.loadImage(at: item.url, item: item)
            if item.isSVG {
                await self?.loadSVGSource(item: item)
            }
        }

        metadataTask = Task { [weak self] in
            await self?.loadMetadata(for: item)
        }
    }

    func clear() {
        currentLoadTask?.cancel()
        metadataTask?.cancel()
        currentItem = nil
        imagePixelSize = .zero
        isCodeMode = false
        imageCanvas.image = nil
        imageCanvas.setFrameSize(.zero)
        codeTextView.string = ""
        mediaInfoView.isHidden = true
    }

    // MARK: - SVG Mode Switching

    private func setSVGMode(_ segment: Int) {
        if segment == 0 {
            // Code mode
            isCodeMode = true
            scrollView.isHidden = true
            codeScrollView.isHidden = false
            codeRulerView.isHidden = false
        } else {
            // Preview mode (image)
            isCodeMode = false
            scrollView.isHidden = false
            codeScrollView.isHidden = true
            codeRulerView.isHidden = true
        }
    }

    private func loadSVGSource(item: FileItem) async {
        do {
            let content = try await Task.detached {
                try String(contentsOf: item.url, encoding: .utf8)
            }.value

            guard !Task.isCancelled, currentItem?.url == item.url else { return }

            updateHighlighterTheme()
            let attributedString: NSAttributedString
            if let highlighter, let highlighted = highlighter.highlight(content, as: "xml") {
                let cleaned = NSMutableAttributedString(attributedString: highlighted)
                cleaned.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: cleaned.length))
                attributedString = cleaned
            } else {
                attributedString = NSAttributedString(string: content, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ])
            }

            codeTextView.textStorage?.setAttributedString(attributedString)
            codeTextView.scrollToBeginningOfDocument(nil)
            codeRulerView.needsDisplay = true
        } catch {
            guard !Task.isCancelled, currentItem?.url == item.url else { return }
            codeTextView.string = ""
        }
    }

    private func updateHighlighterTheme() {
        let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = isDark ? "atom-one-dark" : "atom-one-light"
        highlighter?.setTheme(theme, withFont: "Menlo-Regular", ofSize: 12.0)
        highlighter?.theme.themeBackgroundColour = .clear
    }

    // MARK: - Zoom

    private func toggleFitActualSize() {
        guard imagePixelSize.width > 0 else { return }

        let currentMag = scrollView.magnification
        let fitMag = fitMagnification()

        let targetMag: CGFloat
        if abs(currentMag - fitMag) < 0.01 {
            targetMag = 1.0
        } else {
            targetMag = fitMag
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            scrollView.magnification = targetMag
        }

        updateZoomLabel()
    }

    private func applyFitMagnification() {
        let fitMag = fitMagnification()
        scrollView.minMagnification = min(fitMag, 0.01)
        scrollView.magnification = fitMag
        updateZoomLabel()
    }

    private func fitMagnification() -> CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return 1.0 }
        // Use the scroll view's frame size (stable during magnification changes)
        // rather than contentView.bounds (which scales inversely with magnification).
        let visibleSize = scrollView.frame.size
        let scaleX = visibleSize.width / imagePixelSize.width
        let scaleY = visibleSize.height / imagePixelSize.height
        return min(scaleX, scaleY, 1.0)
    }

    private func centerImageIfNeeded() {
        guard !isCentering else { return }
        isCentering = true
        (scrollView?.contentView as? CenteringClipView)?.centerDocument()
        isCentering = false
    }

    @objc private func magnificationDidChange(_ notification: Notification) {
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        guard let item = currentItem else { return }
        let zoomPercent = Int(round(scrollView.magnification * 100))
        let detail = "\(Int(imagePixelSize.width)) \u{00D7} \(Int(imagePixelSize.height)) — \(item.formattedSize) — \(zoomPercent)%"
        headerView.setCompactDetail(detail)
    }

    // MARK: - Image Loading

    private func loadImage(at url: URL, item: FileItem) async {
        do {
            let (image, dimensions) = try await Task.detached {
                guard let image = NSImage(contentsOf: url) else {
                    throw CocoaError(.fileReadCorruptFile)
                }

                // Get actual pixel dimensions for display in the header.
                var pixelWidth = 0
                var pixelHeight = 0
                if let rep = image.representations.first {
                    pixelWidth = rep.pixelsWide
                    pixelHeight = rep.pixelsHigh
                }
                if pixelWidth <= 0 || pixelHeight <= 0 {
                    pixelWidth = Int(image.size.width)
                    pixelHeight = Int(image.size.height)
                }

                // Normalize image.size to match pixel dimensions so that
                // NSImageView with .scaleNone renders at pixel size.
                // Without this, JPEGs with DPI metadata (e.g. 300 DPI)
                // render at point size which is smaller than the canvas.
                image.size = NSSize(width: pixelWidth, height: pixelHeight)

                return (image, NSSize(width: pixelWidth, height: pixelHeight))
            }.value

            guard !Task.isCancelled, currentItem?.url == item.url else { return }

            imagePixelSize = dimensions
            imageCanvas.image = image
            imageCanvas.setFrameSize(dimensions)

            // Reset last visible size so viewDidLayout re-fits on next pass.
            lastVisibleSize = .zero
            applyFitMagnification()
            centerImageIfNeeded()
        } catch {
            guard !Task.isCancelled, currentItem?.url == item.url else { return }
            imageCanvas.image = nil
            imageCanvas.setFrameSize(.zero)
        }
    }

    // MARK: - Metadata

    private func loadMetadata(for item: FileItem) async {
        guard let metadata = await MediaMetadataExtractor.extractImageMetadata(from: item.url) else {
            return
        }

        guard !Task.isCancelled, currentItem?.url == item.url else { return }

        let rows = makeInfoRows(from: metadata)
        guard !rows.isEmpty else { return }

        let summary = makeCompactSummary(from: metadata)
        mediaInfoView.update(title: "Image Info", compactSummary: summary, rows: rows)
        mediaInfoView.isHidden = false
    }

    private func makeCompactSummary(from meta: ImageMetadata) -> String {
        var parts: [String] = []

        parts.append("\(meta.pixelWidth)\u{00D7}\(meta.pixelHeight)")

        if let dpiX = meta.dpiX {
            parts.append("\(Int(dpiX)) DPI")
        }

        if let colorSpace = meta.colorSpace {
            parts.append(colorSpace)
        }

        return parts.joined(separator: " \u{00B7} ")
    }

    private func makeInfoRows(from meta: ImageMetadata) -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []

        rows.append(MediaInfoRow(label: "Dimensions", value: "\(meta.pixelWidth) \u{00D7} \(meta.pixelHeight)"))
        rows.append(MediaInfoRow(label: "Aspect Ratio", value: meta.aspectRatio))

        if let dpiX = meta.dpiX, let dpiY = meta.dpiY {
            let dpiStr = dpiX == dpiY ? "\(Int(dpiX))" : "\(Int(dpiX)) \u{00D7} \(Int(dpiY))"
            rows.append(MediaInfoRow(label: "DPI", value: dpiStr))
        }

        if let colorSpace = meta.colorSpace {
            var detail = colorSpace
            if let bits = meta.bitDepth { detail += " (\(bits)-bit)" }
            if let alpha = meta.hasAlpha, alpha { detail += ", alpha" }
            rows.append(MediaInfoRow(label: "Color", value: detail))
        }

        if let model = meta.cameraModel {
            let camera = [meta.cameraMake, model]
                .compactMap { $0 }
                .joined(separator: " ")
            rows.append(MediaInfoRow(label: "Camera", value: camera))
        }

        if let lens = meta.lensModel {
            rows.append(MediaInfoRow(label: "Lens", value: lens))
        }

        // Exposure line: focal length, aperture, shutter, ISO combined
        var exposureParts: [String] = []
        if let fl = meta.focalLength { exposureParts.append("\(Int(fl))mm") }
        if let ap = meta.aperture { exposureParts.append(String(format: "\u{0192}/%.1f", ap)) }
        if let ss = meta.shutterSpeed { exposureParts.append(ss) }
        if let iso = meta.iso { exposureParts.append("ISO \(iso)") }
        if !exposureParts.isEmpty {
            rows.append(MediaInfoRow(label: "Exposure", value: exposureParts.joined(separator: " \u{00B7} ")))
        }

        if let flash = meta.flash {
            rows.append(MediaInfoRow(label: "Flash", value: flash ? "Fired" : "Off"))
        }

        if let date = meta.dateTaken {
            rows.append(MediaInfoRow(label: "Date Taken", value: date.fullFormatted))
        }

        if let gps = meta.formattedGPS {
            rows.append(MediaInfoRow(label: "Location", value: gps))
        }

        if let alt = meta.gpsAltitude {
            rows.append(MediaInfoRow(label: "Altitude", value: String(format: "%.0fm", alt)))
        }

        return rows
    }
}

// MARK: - ImageCanvasView

/// Simple view that displays an image at its native pixel dimensions.
/// Uses NSImageView with `.scaleNone` so all scaling is handled exclusively
/// by the parent NSScrollView's magnification system. Supports animated GIFs.
private final class ImageCanvasView: NSView {
    var image: NSImage? {
        didSet {
            imageView.image = image
            imageView.animates = true
        }
    }

    var onDoubleClick: (() -> Void)?

    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleNone
        imageView.animates = true
        imageView.isEditable = false
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Pin imageView to exact same size — no autoresizing mask to avoid
        // conflicts with NSScrollView's magnification transform.
        imageView.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

// MARK: - CenteringClipView

/// NSClipView subclass that centers its document view when the document
/// is smaller than the visible area, giving a centered image appearance.
/// All comparisons use the document view's frame (unscaled), and proposed
/// bounds are also in document coordinates (NSScrollView divides by
/// magnification before calling this method).
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }

        // Both docFrame and proposedBounds are in document (unscaled) coordinates.
        // NSScrollView already divides the clip view's visual size by magnification
        // before passing it here, so direct comparison is correct.
        let docFrame = documentView.frame

        if docFrame.width < proposedBounds.width {
            rect.origin.x = (docFrame.width - proposedBounds.width) / 2
        }

        if docFrame.height < proposedBounds.height {
            rect.origin.y = (docFrame.height - proposedBounds.height) / 2
        }

        return rect
    }

    func centerDocument() {
        scroll(to: constrainBoundsRect(bounds).origin)
    }
}
