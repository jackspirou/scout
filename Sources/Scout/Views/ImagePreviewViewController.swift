import AppKit

// MARK: - ImagePreviewViewController

/// Displays an image file with a collapsible metadata header, media info section,
/// and zoomable/pannable image canvas.
/// Supports zoom (pinch, scroll-wheel, double-click) and drag-to-pan.
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

    private var imagePixelSize: NSSize = .zero
    private var isCentering = false

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configureScrollView()

        // MediaInfoView starts hidden — shown once metadata loads.
        mediaInfoView.isHidden = true

        view.addSubview(headerView)
        view.addSubview(mediaInfoView)

        layoutSubviews()

        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.headerView.updateAppearance()
            self?.mediaInfoView.updateAppearance()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
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
        scrollView.minMagnification = 0.1
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

    private func layoutSubviews() {
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
        ])
    }

    // MARK: - Public API

    func displayItem(_ item: FileItem) {
        currentLoadTask?.cancel()
        metadataTask?.cancel()
        currentItem = item
        imagePixelSize = .zero
        mediaInfoView.isHidden = true

        headerView.update(with: item)

        currentLoadTask = Task { [weak self] in
            await self?.loadImage(at: item.url, item: item)
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
        imageCanvas.image = nil
        imageCanvas.setFrameSize(.zero)
        mediaInfoView.isHidden = true
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

    private func fitMagnification() -> CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return 1.0 }
        let visibleSize = scrollView.contentView.bounds.size
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

                var width = 0
                var height = 0
                if let rep = image.representations.first {
                    width = rep.pixelsWide
                    height = rep.pixelsHigh
                }
                if width <= 0 || height <= 0 {
                    width = Int(image.size.width)
                    height = Int(image.size.height)
                }

                return (image, NSSize(width: width, height: height))
            }.value

            guard !Task.isCancelled, currentItem?.url == item.url else { return }

            imagePixelSize = dimensions
            imageCanvas.image = image
            imageCanvas.setFrameSize(dimensions)

            scrollView.magnification = fitMagnification()
            centerImageIfNeeded()
            updateZoomLabel()
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

/// Simple view that draws an image filling its bounds. Sized to the image's
/// pixel dimensions and used as the document view of a zooming scroll view.
private final class ImageCanvasView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onDoubleClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
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
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }

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
