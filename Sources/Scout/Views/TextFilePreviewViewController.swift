import AppKit
import Highlighter
import WebKit

// MARK: - TextFilePreviewViewController

/// Displays read-only syntax-highlighted text content with line numbers and a file metadata header.
/// For markdown and HTML files, supports toggling between raw code and rendered preview via WKWebView.
/// Designed to be embedded as a child view controller within PreviewViewController.
final class TextFilePreviewViewController: NSViewController, PreviewChild {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()

    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var rulerView: LineNumberRulerView!

    private var webView: WKWebView!
    private var loadingSpinner: NSProgressIndicator!
    private var errorLabel: NSTextField!
    private var isPreviewMode = false
    private var templateLoaded = false
    /// Content waiting to be injected once the template finishes loading.
    private var pendingMarkdownContent: String?
    private var navigationTimeoutTimer: Timer?

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
        configureWebView()
        configureSpinner()

        // Add header LAST so it draws on top of ruler/scroll view.
        view.addSubview(headerView)

        layoutSubviews()

        highlighter = Highlighter()
        updateHighlighterTheme()

        headerView.onModeChanged = { [weak self] segment in
            self?.setMode(segment)
        }

        // Observe appearance changes to update syntax highlighting theme.
        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self = self else { return }
            self.updateHighlighterTheme()
            self.headerView.updateAppearance()

            // Re-highlight cached content without re-reading from disk.
            if let content = self.currentContent {
                if self.isPreviewMode {
                    if self.currentItem?.isMermaid == true {
                        self.loadMermaidPreview(content: content)
                    } else if self.currentItem?.isMarkdown == true {
                        self.loadMarkdownPreview(content: content)
                    } else if self.currentItem?.isHTML == true {
                        self.loadHTMLPreview(content: content)
                    }
                } else {
                    let attributedString: NSAttributedString
                    if self.currentItem?.isMermaid == true {
                        let isDark = self.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        attributedString = MermaidHighlighter.highlight(content, fontSize: Layout.fontSize, isDark: isDark)
                    } else if let language = self.currentLanguage,
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

    private func configureWebView() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        // Track failed resource loads so we can warn when the page renders blank.
        let errorScript = WKUserScript(source: """
            window.__failedResources = [];
            window.addEventListener('error', function(e) {
                if (e.target !== window && e.target.tagName) {
                    window.__failedResources.push(e.target.src || e.target.href || e.target.tagName);
                }
            }, true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(errorScript)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        view.addSubview(webView)
    }

    private func configureSpinner() {
        loadingSpinner = NSProgressIndicator()
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isHidden = true
        view.addSubview(loadingSpinner)

        errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        errorLabel.textColor = .systemRed
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        view.addSubview(errorLabel)
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

            webView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 1),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Public API

    /// Previews the given file item. Updates the header and loads syntax-highlighted text.
    func displayItem(_ item: FileItem) {
        currentLoadTask?.cancel()
        currentLanguage = item.highlightrLanguage
        currentItem = item
        templateLoaded = false
        pendingMarkdownContent = nil
        pendingMermaidContent = nil

        headerView.update(with: item)

        let hasPreview = item.isMarkdown || item.isHTML || item.isMermaid
        headerView.setMarkdownMode(hasPreview)

        // For preview-capable files, hide everything and show spinner while loading.
        if hasPreview {
            scrollView.isHidden = true
            rulerView.isHidden = true
            webView.isHidden = true
            errorLabel.isHidden = true
            showSpinner()
        }

        let language = item.highlightrLanguage
        currentLoadTask = Task { [weak self] in
            await self?.loadTextFile(item: item, language: language)
            if hasPreview {
                self?.setMode(1) // Default to Preview for markdown/HTML
            } else {
                self?.setMode(0) // Code mode for other text files
            }
        }
    }

    /// Clears the preview, cancels any in-flight load, and resets all state.
    func clear() {
        currentLoadTask?.cancel()
        cancelNavigationTimeout()
        currentLanguage = nil
        currentContent = nil
        currentItem = nil
        isPreviewMode = false
        pendingMarkdownContent = nil
        pendingMermaidContent = nil
        textView.string = ""
        webView.stopLoading()
        templateLoaded = false
        errorLabel.isHidden = true
        hideSpinner()
    }

    // MARK: - Mode Switching

    private func setMode(_ segment: Int) {
        guard let item = currentItem else { return }

        if segment == 1 && (item.isMarkdown || item.isHTML || item.isMermaid) {
            // Preview mode
            isPreviewMode = true
            scrollView.isHidden = true
            rulerView.isHidden = true
            if let content = currentContent {
                if item.isMermaid {
                    loadMermaidPreview(content: content)
                } else if item.isMarkdown {
                    loadMarkdownPreview(content: content)
                } else if item.isHTML {
                    loadHTMLPreview(content: content)
                }
            }
        } else {
            // Code mode
            isPreviewMode = false
            hideSpinner()
            errorLabel.isHidden = true
            scrollView.isHidden = false
            rulerView.isHidden = false
            webView.isHidden = true
        }
    }

    // MARK: - Loading Indicator

    private func showSpinner() {
        loadingSpinner.isHidden = false
        loadingSpinner.startAnimation(nil)
    }

    private func hideSpinner() {
        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true
    }

    // MARK: - Navigation Timeout

    private func startNavigationTimeout() {
        navigationTimeoutTimer?.invalidate()
        navigationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isPreviewMode, self.webView.isHidden else { return }
            self.webView.stopLoading()
            let name = self.currentItem?.name ?? "file"
            self.showRenderError("Preview Timed Out — \(name)\nLoading took longer than 5 seconds. The file may reference external resources that are unreachable. Try the Code view instead.")
        }
    }

    private func cancelNavigationTimeout() {
        navigationTimeoutTimer?.invalidate()
        navigationTimeoutTimer = nil
    }

    // MARK: - Markdown Preview

    private func loadMarkdownPreview(content: String) {
        if !templateLoaded {
            guard let templateURL = Bundle.module.url(forResource: "markdown-template", withExtension: "html"),
                  let html = try? String(contentsOf: templateURL, encoding: .utf8) else { return }
            // Store content to inject after template finishes loading (via didFinishNavigation).
            pendingMarkdownContent = content
            startNavigationTimeout()
            webView.loadHTMLString(html, baseURL: nil)
            templateLoaded = true
        } else {
            injectMarkdown(content)
            hideSpinner()
            webView.isHidden = false
        }
    }

    private func injectMarkdown(_ content: String) {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        webView.evaluateJavaScript("renderMarkdown(`\(escaped)`)")
    }

    // MARK: - Mermaid Preview

    private func loadMermaidPreview(content: String) {
        // Reuse the markdown template which already bundles mermaid.js.
        // Instead of calling renderMarkdown(), we inject the mermaid source
        // directly into a <div class="mermaid"> and trigger mermaid.run().
        guard let templateURL = Bundle.module.url(forResource: "markdown-template", withExtension: "html"),
              let html = try? String(contentsOf: templateURL, encoding: .utf8) else { return }

        // Load template, then inject mermaid content after it finishes loading.
        pendingMarkdownContent = nil
        templateLoaded = false
        pendingMermaidContent = content
        startNavigationTimeout()
        webView.loadHTMLString(html, baseURL: nil)
    }

    private var pendingMermaidContent: String?

    private func injectMermaid(_ content: String) {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let js = """
        (function() {
            var el = document.getElementById('content');
            var div = document.createElement('div');
            div.className = 'mermaid';
            div.textContent = `\(escaped)`;
            el.innerHTML = '';
            el.appendChild(div);
            if (typeof mermaid !== 'undefined') {
                mermaid.initialize({
                    startOnLoad: false,
                    theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default'
                });
                mermaid.run({ nodes: el.querySelectorAll('.mermaid') });
            }
        })();
        """
        webView.evaluateJavaScript(js)
    }

    // MARK: - HTML Preview

    private func loadHTMLPreview(content: String) {
        let baseURL = currentItem?.url.deletingLastPathComponent()
        pendingMarkdownContent = nil
        startNavigationTimeout()
        webView.loadHTMLString(content, baseURL: baseURL)
        templateLoaded = false
        // webView revealed in didFinishNavigation
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
            if item.isMermaid {
                let isDark = await MainActor.run {
                    view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                }
                attributedString = MermaidHighlighter.highlight(content, fontSize: Layout.fontSize, isDark: isDark)
            } else if let language,
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

// MARK: - WKNavigationDelegate

extension TextFilePreviewViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        cancelNavigationTimeout()

        // Template loaded — inject pending content if any.
        if let content = pendingMermaidContent {
            pendingMermaidContent = nil
            injectMermaid(content)
            // Mermaid rendering is async — give it a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.hideSpinner()
                self?.webView.isHidden = false
            }
        } else if let content = pendingMarkdownContent {
            pendingMarkdownContent = nil
            injectMarkdown(content)
            // Brief delay to let JS render before revealing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.hideSpinner()
                self?.webView.isHidden = false
            }
        } else {
            // HTML preview — reveal immediately, then check for blank page.
            hideSpinner()
            webView.isHidden = false
            checkForBlankPage()
        }
    }

    /// After a brief delay, checks if the rendered page is blank with failed resources.
    private func checkForBlankPage() {
        guard currentItem?.isHTML == true else { return }
        let itemURL = currentItem?.url

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self,
                  self.isPreviewMode,
                  self.currentItem?.url == itemURL else { return }

            let js = """
            (function() {
                var text = (document.body ? document.body.innerText : '').trim();
                var failed = window.__failedResources ? window.__failedResources.length : 0;
                return JSON.stringify({ textLength: text.length, failedResources: failed });
            })()
            """
            self.webView.evaluateJavaScript(js) { result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let textLength = info["textLength"] as? Int,
                      let failedResources = info["failedResources"] as? Int,
                      self.currentItem?.url == itemURL else { return }

                if textLength == 0 && failedResources > 0 {
                    let name = self.currentItem?.name ?? "file"
                    self.showRenderError("Preview Blank — \(name)\nThe page rendered with no visible content. \(failedResources) external resource\(failedResources == 1 ? "" : "s") failed to load. The file may require a web server or network access. Try the Code view instead.")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showRenderError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showRenderError(error)
    }

    private func showRenderError(_ message: String) {
        cancelNavigationTimeout()
        hideSpinner()
        webView.isHidden = true
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    private func showRenderError(_ error: Error) {
        let name = currentItem?.name ?? "file"
        showRenderError("Render Error — \(name)\n\(error.localizedDescription)")
    }
}
