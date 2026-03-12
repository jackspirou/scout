import AppKit
import Highlighter

// MARK: - TextFilePreviewViewController

/// Displays read-only syntax-highlighted text content with line numbers and a file metadata header.
/// Designed to be embedded as a child view controller within PreviewViewController.
final class TextFilePreviewViewController: NSViewController {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()

    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var rulerView: LineNumberRulerView!

    private var currentItem: FileItem?
    private var currentLoadTask: Task<Void, Never>?
    private var currentLanguage: String?
    private var currentContent: String?
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

        configureTextSystem()

        // Add header LAST so it draws on top of ruler/scroll view.
        view.addSubview(headerView)

        layoutSubviews()

        highlighter = Highlighter()
        updateHighlighterTheme()

        // Observe appearance changes to update syntax highlighting theme.
        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self = self else { return }
            self.updateHighlighterTheme()
            self.headerView.updateAppearance()

            // Re-highlight cached content without re-reading from disk.
            if let content = self.currentContent {
                let attributedString: NSAttributedString
                if let language = self.currentLanguage,
                   let highlighter = self.highlighter,
                   let highlighted = highlighter.highlight(content, as: language) {
                    attributedString = highlighted
                } else {
                    attributedString = Self.plainAttributedString(from: content)
                }
                self.showTextContent(attributedString)
            }
        }
    }

    // MARK: - Configuration

    private func configureTextSystem() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.font = NSFont.monospacedSystemFont(ofSize: Layout.fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false // Let scroll view handle background

        // Word-wrap to the scroll view width. Vertical scrolling only.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 8)

        scrollView.documentView = textView
        rulerView = LineNumberRulerView(textView: textView, scrollView: scrollView)

        view.addSubview(rulerView)
        view.addSubview(scrollView)
    }

    private func layoutSubviews() {
        let rulerWidthConstraint = rulerView.widthAnchor.constraint(equalToConstant: rulerView.gutterWidth)
        rulerView.setWidthConstraint(rulerWidthConstraint)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            rulerView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 1),
            rulerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rulerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rulerWidthConstraint,

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rulerView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Public API

    /// Previews the given file item. Updates the header and loads syntax-highlighted text.
    func displayItem(_ item: FileItem) {
        currentLoadTask?.cancel()
        currentLanguage = item.highlightrLanguage
        currentItem = item

        headerView.update(with: item)

        let language = item.highlightrLanguage
        currentLoadTask = Task { [weak self] in
            await self?.loadTextFile(item: item, language: language)
        }
    }

    /// Clears the preview, cancels any in-flight load, and resets all state.
    func clear() {
        currentLoadTask?.cancel()
        currentLanguage = nil
        currentContent = nil
        currentItem = nil
        textView.string = ""
    }

    // MARK: - Private Helpers

    private func updateHighlighterTheme() {
        let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = isDark ? "atom-one-dark" : "atom-one-light"
        highlighter?.setTheme(theme, withFont: "Menlo-Regular", ofSize: 12.0)
        highlighter?.theme.themeBackgroundColour = .clear
    }

    /// Strips Highlightr's background color and sets the attributed string in the text view.
    private func showTextContent(_ attributedString: NSAttributedString) {
        let cleanedString = NSMutableAttributedString(attributedString: attributedString)
        cleanedString.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: cleanedString.length))

        textView.textStorage?.setAttributedString(cleanedString)
        textView.scrollToBeginningOfDocument(nil)
        rulerView.needsDisplay = true
    }

    /// Reads up to `maxFileSize` bytes from the given URL with encoding cascade.
    private func loadTextFile(item: FileItem, language: String?) async {
        do {
            let (text, fileSize) = try await Task.detached {
                let handle = try FileHandle(forReadingFrom: item.url)
                defer { try? handle.close() }

                let fileSize = Int64(handle.seekToEndOfFile())
                handle.seek(toFileOffset: 0)

                let bytesToRead = min(Int(fileSize), Layout.maxFileSize)
                let data = handle.readData(ofLength: bytesToRead)

                return (Self.decodeText(from: data), fileSize)
            }.value

            guard !Task.isCancelled, currentItem?.url == item.url else { return }

            var content = text
            if fileSize > Layout.maxPreviewBytes {
                content += "\n\n--- Preview truncated (showing first 512 KB of \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))) ---"
            }

            currentContent = content

            let attributedString: NSAttributedString
            if let language,
               let highlighter = highlighter {
                updateHighlighterTheme()
                attributedString = highlighter.highlight(content, as: language)
                    ?? Self.plainAttributedString(from: content)
            } else {
                attributedString = Self.plainAttributedString(from: content)
            }

            showTextContent(attributedString)
        } catch {
            guard !Task.isCancelled, currentItem?.url == item.url else { return }
            textView.string = ""
        }
    }

    private static func plainAttributedString(from text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: Layout.fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    private nonisolated static func decodeText(from data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        for encoding: String.Encoding in [.utf16, .windowsCP1252, .macOSRoman] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }

        return String(data: data, encoding: .isoLatin1)
            ?? String(repeating: "\u{FFFD}", count: data.count)
    }
}
