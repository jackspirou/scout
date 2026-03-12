import AppKit
import Highlighter

// MARK: - TextFilePreviewViewController

/// Displays a read-only text preview of the currently selected file.
final class TextFilePreviewViewController: NSViewController {
    // MARK: - Properties

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let placeholderLabel = NSTextField(labelWithString: "Select a file to preview")

    private var currentLoadTask: Task<Void, Never>?
    private var currentFileURL: URL?
    private var currentLanguage: String?
    private var highlighter: Highlighter?
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Constants

    private enum Layout {
        static let maxFileSize: Int = 512 * 1024 // 512 KB
        static let maxPreviewBytes: Int64 = Int64(maxFileSize)
        static let fontSize: CGFloat = 12
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        configureScrollView()
        configureTextView()
        configurePlaceholder()
        layoutSubviews()

        let rulerView = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = rulerView

        highlighter = Highlighter()
        updateHighlighterTheme()

        // Observe appearance changes to update syntax highlighting theme.
        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self = self else { return }
            self.updateHighlighterTheme()

            // Re-highlight current content if any.
            if let url = self.currentFileURL {
                let language = self.currentLanguage
                self.currentLoadTask?.cancel()
                self.currentLoadTask = Task { [weak self] in
                    await self?.loadTextFile(at: url, language: language)
                }
            }
        }
    }

    // MARK: - Configuration

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.isHidden = true
        view.addSubview(scrollView)
    }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.font = NSFont.monospacedSystemFont(ofSize: Layout.fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false // Let scroll view handle background
        textView.textContainerInset = NSSize(width: 4, height: 4)

        // Word-wrap to the scroll view width. Vertical scrolling only.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
    }

    private func configurePlaceholder() {
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = NSFont.systemFont(ofSize: 14)
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.isHidden = false
        view.addSubview(placeholderLabel)
    }

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Public API

    /// Previews the given file item. Shows text content for text files, placeholder otherwise.
    func previewItem(_ item: FileItem?) {
        currentLoadTask?.cancel()
        currentFileURL = item?.url
        currentLanguage = item?.highlightrLanguage

        guard let item = item else {
            clearPreview()
            return
        }

        guard item.isText else {
            showPlaceholder()
            return
        }

        let language = item.highlightrLanguage
        currentLoadTask = Task { [weak self] in
            await self?.loadTextFile(at: item.url, language: language)
        }
    }

    /// Clears the preview and shows the placeholder label.
    func clearPreview() {
        currentLoadTask?.cancel()
        currentFileURL = nil
        currentLanguage = nil
        showPlaceholder()
    }

    // MARK: - Private Helpers

    private func updateHighlighterTheme() {
        let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = isDark ? "atom-one-dark" : "atom-one-light"
        highlighter?.setTheme(theme, withFont: "Menlo-Regular", ofSize: 12.0)
        highlighter?.theme.themeBackgroundColour = .clear
    }

    private func showPlaceholder() {
        textView.string = ""
        scrollView.isHidden = true
        placeholderLabel.isHidden = false
    }

    private func showTextContent(_ attributedString: NSAttributedString) {
        textView.textStorage?.setAttributedString(attributedString)
        textView.scrollToBeginningOfDocument(nil)
        scrollView.isHidden = false
        placeholderLabel.isHidden = true
        scrollView.verticalRulerView?.needsDisplay = true
    }

    /// Reads up to `maxFileSize` bytes from the given URL with encoding cascade.
    private func loadTextFile(at url: URL, language: String?) async {
        do {
            // Read and decode off the main thread.
            let (text, fileSize) = try await Task.detached {
                let fileData = try Data(contentsOf: url, options: .mappedIfSafe)
                let fileSize = Int64(fileData.count)
                let data = fileData.count > Layout.maxFileSize
                    ? fileData.prefix(Layout.maxFileSize)
                    : fileData
                return (Self.decodeText(from: data), fileSize)
            }.value

            guard !Task.isCancelled else { return }

            var content = text
            if fileSize > Layout.maxPreviewBytes {
                content += "\n\n--- Preview truncated (showing first 512 KB of \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))) ---"
            }

            // Ensure theme matches current appearance (may not be correct from loadView).
            updateHighlighterTheme()

            // Apply syntax highlighting.
            let attributedString: NSAttributedString
            if let highlighter = highlighter,
               let highlighted = highlighter.highlight(content, as: language) {
                attributedString = highlighted
            } else {
                attributedString = Self.plainAttributedString(from: content)
            }

            showTextContent(attributedString)
        } catch {
            guard !Task.isCancelled else { return }
            showPlaceholder()
        }
    }

    /// Creates a plain monospaced attributed string for fallback display.
    private static func plainAttributedString(from text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: Layout.fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    /// Attempts to decode data as text using a cascade of encodings.
    private nonisolated static func decodeText(from data: Data) -> String {
        // Try UTF-8 first (covers the vast majority of developer files).
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        // Try common encodings.
        for encoding: String.Encoding in [.utf16, .windowsCP1252, .macOSRoman] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }

        // Fall back to Latin-1 (never fails).
        return String(data: data, encoding: .isoLatin1)
            ?? String(repeating: "\u{FFFD}", count: data.count)
    }

}
