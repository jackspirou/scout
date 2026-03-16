import AppKit

// MARK: - DocumentPreviewViewController

/// Displays rich document files (.docx, .doc, .rtf, .rtfd, .odt) with a metadata header
/// and rendered content using NSAttributedString's native document reading capabilities.
final class DocumentPreviewViewController: NSViewController, PreviewChild {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var loadingSpinner: NSProgressIndicator!
    private var errorLabel: NSTextField!
    private var currentItem: FileItem?
    private var loadGeneration: Int = 0
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configureScrollView()
        configureLoadingSpinner()
        configureErrorLabel()

        view.addSubview(headerView)

        layoutSubviews()

        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.headerView.updateAppearance()
        }
    }

    // MARK: - Configuration

    private func configureScrollView() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white

        // Let NSTextView create its own TextContainer/LayoutManager/TextStorage.
        // Manual creation + Auto Layout causes zero-frame rendering issues.
        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false // scroll view handles background
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        view.addSubview(scrollView)
    }

    private func configureLoadingSpinner() {
        loadingSpinner = NSProgressIndicator()
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isDisplayedWhenStopped = false
        view.addSubview(loadingSpinner)
    }

    private func configureErrorLabel() {
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = NSFont.systemFont(ofSize: 13)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true
        view.addSubview(errorLabel)
    }

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Public API

    func displayItem(_ item: FileItem) {
        loadGeneration += 1
        currentItem = item
        errorLabel.isHidden = true
        scrollView.isHidden = true

        headerView.update(with: item)
        loadingSpinner.startAnimation(nil)

        let generation = loadGeneration
        let url = item.url
        let size = item.formattedSize

        let docType = Self.documentType(for: url.pathExtension)

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<NSAttributedString, any Error>
            do {
                // Try with explicit document type first, then fall back to auto-detection.
                let attrString: NSAttributedString
                if let docType {
                    attrString = try NSAttributedString(
                        url: url,
                        options: [.documentType: docType],
                        documentAttributes: nil
                    )
                } else {
                    attrString = try NSAttributedString(
                        url: url, options: [:], documentAttributes: nil
                    )
                }
                result = .success(attrString)
            } catch {
                // Explicit type failed — retry with auto-detection as fallback.
                do {
                    let attrString = try NSAttributedString(
                        url: url, options: [:], documentAttributes: nil
                    )
                    result = .success(attrString)
                } catch {
                    result = .failure(error)
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.loadingSpinner.stopAnimation(nil)

                switch result {
                case .success(let attrString):
                    let fixedString = Self.fixInvisibleTextColors(in: attrString)
                    self.textView.textStorage?.setAttributedString(fixedString)
                    self.scrollView.isHidden = false
                    self.errorLabel.isHidden = true
                    self.headerView.setCompactDetail(size)
                case .failure(let error):
                    self.scrollView.isHidden = true
                    self.errorLabel.stringValue = "Unable to read document: \(error.localizedDescription)"
                    self.errorLabel.isHidden = false
                }
            }
        }
    }

    // MARK: - Text Color Fix

    /// Some .doc files embed white or near-white foreground colors (intended for
    /// printing on white paper). Replace any such colors with `.labelColor` so
    /// text remains readable on our white preview background.
    private static func fixInvisibleTextColors(in source: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            // Convert to sRGB to get comparable brightness. If conversion fails, skip.
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            let brightness = rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114
            if brightness > 0.9 {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }

        return mutable
    }

    // MARK: - Document Type Mapping

    private static func documentType(for ext: String) -> NSAttributedString.DocumentType? {
        switch ext.lowercased() {
        case "docx":
            return .officeOpenXML
        case "doc":
            return .docFormat
        case "rtf":
            return .rtf
        case "rtfd":
            return .rtfd
        case "odt":
            return .openDocument
        default:
            return nil
        }
    }

    func clear() {
        loadGeneration += 1
        currentItem = nil
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        errorLabel.isHidden = true
        loadingSpinner.stopAnimation(nil)
        scrollView.isHidden = true
    }
}
