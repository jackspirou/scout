import AppKit
import Highlighter

// MARK: - TextFilePreviewViewController

/// Displays read-only syntax-highlighted text content with line numbers and a file metadata header.
/// Designed to be embedded as a child view controller within PreviewViewController.
final class TextFilePreviewViewController: NSViewController {
    // MARK: - Properties

    private var headerView: NSView!
    private var headerIconView: NSImageView!
    private var headerNameLabel: NSTextField!
    private var compactDetailLabel: NSTextField!
    private var disclosureButton: NSButton!
    private var detailGrid: NSGridView!
    private var headerSeparator: NSBox!
    private var headerHeightConstraint: NSLayoutConstraint!

    // Detail value labels for the expanded metadata grid.
    private var sizeValueLabel: NSTextField!
    private var kindValueLabel: NSTextField!
    private var createdValueLabel: NSTextField!
    private var modifiedValueLabel: NSTextField!
    private var lastOpenedValueLabel: NSTextField!
    private var lockedValueLabel: NSTextField!
    private var permissionsValueLabel: NSTextField!
    private var whereValueLabel: NSTextField!
    private var copyPathButton: NSButton!

    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var rulerView: LineNumberRulerView!

    private var isHeaderExpanded = false
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
        static let collapsedHeaderHeight: CGFloat = 30
        static let expandedHeaderHeight: CGFloat = 112
        static let gridLabelWidth: CGFloat = 60
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configureHeader()
        configureTextSystem()

        // Add header + separator LAST so they draw on top of ruler/scroll view.
        view.addSubview(headerView)
        view.addSubview(headerSeparator)

        layoutSubviews()

        highlighter = Highlighter()
        updateHighlighterTheme()

        // Observe appearance changes to update syntax highlighting theme.
        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self = self else { return }
            self.updateHighlighterTheme()
            self.headerView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

            // Re-highlight cached content without re-reading from disk.
            if let content = self.currentContent {
                let attributedString: NSAttributedString
                if let highlighter = self.highlighter,
                   let highlighted = highlighter.highlight(content, as: self.currentLanguage) {
                    attributedString = highlighted
                } else {
                    attributedString = Self.plainAttributedString(from: content)
                }
                self.showTextContent(attributedString)
            }
        }
    }

    // MARK: - Configuration

    private func configureHeader() {
        headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        // Use layer-backed background instead of draw(_:) to avoid dirtyRect bleeding.
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        headerIconView = NSImageView()
        headerIconView.translatesAutoresizingMaskIntoConstraints = false
        headerIconView.imageScaling = .scaleProportionallyDown

        headerNameLabel = NSTextField(labelWithString: "")
        headerNameLabel.translatesAutoresizingMaskIntoConstraints = false
        headerNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        headerNameLabel.textColor = .labelColor
        headerNameLabel.lineBreakMode = .byTruncatingMiddle
        headerNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Shows "size · kind" inline — visible in both collapsed and expanded states.
        compactDetailLabel = NSTextField(labelWithString: "")
        compactDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        compactDetailLabel.font = NSFont.systemFont(ofSize: 11)
        compactDetailLabel.textColor = .secondaryLabelColor
        compactDetailLabel.lineBreakMode = .byTruncatingTail
        compactDetailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        disclosureButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand")!,
                                    target: self, action: #selector(toggleHeaderExpansion))
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.bezelStyle = .inline
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.symbolConfiguration = .init(pointSize: 10, weight: .medium)

        configureDetailGrid()

        // Use .custom boxType for a true 1px separator; .separator has ~5px intrinsic height.
        headerSeparator = NSBox()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.boxType = .custom
        headerSeparator.borderWidth = 0
        headerSeparator.fillColor = .separatorColor

        // Clickable overlay covers the name row so tapping anywhere on it toggles expansion.
        let clickableRow = ClickableView(target: self, action: #selector(toggleHeaderExpansion))
        clickableRow.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(headerIconView)
        headerView.addSubview(headerNameLabel)
        headerView.addSubview(compactDetailLabel)
        headerView.addSubview(detailGrid)
        // Clickable overlay and disclosure button go on top of other subviews.
        headerView.addSubview(clickableRow)
        headerView.addSubview(disclosureButton)

        NSLayoutConstraint.activate([
            clickableRow.topAnchor.constraint(equalTo: headerView.topAnchor),
            clickableRow.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            clickableRow.trailingAnchor.constraint(equalTo: disclosureButton.leadingAnchor),
            clickableRow.heightAnchor.constraint(equalToConstant: Layout.collapsedHeaderHeight),
        ])
    }

    /// Builds a 4-row × 4-column NSGridView for the expanded metadata.
    /// Row 1: Size/Kind, Row 2: Created/Modified, Row 3: Opened/Locked,
    /// Row 4: Permissions/Where.
    private func configureDetailGrid() {
        let sizeLabel = makeGridLabel("Size")
        sizeValueLabel = makeGridValue()

        let kindLabel = makeGridLabel("Kind")
        kindValueLabel = makeGridValue()

        let createdLabel = makeGridLabel("Created")
        createdValueLabel = makeGridValue()

        let modifiedLabel = makeGridLabel("Modified")
        modifiedValueLabel = makeGridValue()

        let openedLabel = makeGridLabel("Opened")
        lastOpenedValueLabel = makeGridValue()

        let lockedLabel = makeGridLabel("Locked")
        lockedValueLabel = makeGridValue()

        let permsLabel = makeGridLabel("Perms")
        permissionsValueLabel = makeGridValue()

        let whereLabel = makeGridLabel("Where")
        whereValueLabel = makeGridValue()
        whereValueLabel.lineBreakMode = .byTruncatingTail

        // Copy-to-clipboard button sits next to the Where value.
        copyPathButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy path")!,
                                  target: self, action: #selector(copyPathClicked))
        copyPathButton.translatesAutoresizingMaskIntoConstraints = false
        copyPathButton.bezelStyle = .inline
        copyPathButton.isBordered = false
        copyPathButton.imagePosition = .imageOnly
        copyPathButton.symbolConfiguration = .init(pointSize: 10, weight: .regular)

        let whereValueStack = NSStackView(views: [copyPathButton, whereValueLabel])
        whereValueStack.orientation = .horizontal
        whereValueStack.spacing = 2
        copyPathButton.widthAnchor.constraint(equalToConstant: 16).isActive = true

        // 4 rows × 4 columns: [label, value, label, value]
        detailGrid = NSGridView(views: [
            [sizeLabel, sizeValueLabel, kindLabel, kindValueLabel],
            [createdLabel, createdValueLabel, openedLabel, lastOpenedValueLabel],
            [modifiedLabel, modifiedValueLabel, lockedLabel, lockedValueLabel],
            [permsLabel, permissionsValueLabel, whereLabel, whereValueStack],
        ])
        detailGrid.translatesAutoresizingMaskIntoConstraints = false

        // Label columns: fixed width, right-aligned text fills the cell.
        for col in [0, 2] {
            detailGrid.column(at: col).xPlacement = .fill
            detailGrid.column(at: col).width = Layout.gridLabelWidth
        }

        // Value columns: fill remaining space so values can stretch.
        for col in [1, 3] {
            detailGrid.column(at: col).xPlacement = .fill
        }

        detailGrid.rowSpacing = 4
        detailGrid.columnSpacing = 4
        detailGrid.isHidden = true
    }

    /// Creates a left-aligned label for the grid's label columns.
    private func makeGridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        return label
    }

    /// Creates a flexible value field for the grid's value columns.
    private func makeGridValue() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

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

        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: Layout.collapsedHeaderHeight)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerHeightConstraint,

            // Icon — stays 16×16 in both collapsed and expanded states.
            headerIconView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 8),
            headerIconView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            headerIconView.widthAnchor.constraint(equalToConstant: 16),
            headerIconView.heightAnchor.constraint(equalToConstant: 16),

            // Filename
            headerNameLabel.leadingAnchor.constraint(equalTo: headerIconView.trailingAnchor, constant: 6),
            headerNameLabel.centerYAnchor.constraint(equalTo: headerIconView.centerYAnchor),

            // Compact detail (size · kind) — stays visible in expanded state too.
            compactDetailLabel.leadingAnchor.constraint(equalTo: headerNameLabel.trailingAnchor, constant: 8),
            compactDetailLabel.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -4),
            compactDetailLabel.centerYAnchor.constraint(equalTo: headerIconView.centerYAnchor),

            // Disclosure button
            disclosureButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            disclosureButton.centerYAnchor.constraint(equalTo: headerIconView.centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 16),
            disclosureButton.heightAnchor.constraint(equalToConstant: 16),

            // Detail grid starts right below the name row.
            detailGrid.topAnchor.constraint(equalTo: headerView.topAnchor, constant: Layout.collapsedHeaderHeight + 2),
            detailGrid.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 8),
            detailGrid.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),

            // Separator
            headerSeparator.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),

            // Ruler below separator
            rulerView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            rulerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rulerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rulerWidthConstraint,

            // Scroll view fills the rest below separator
            scrollView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
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

        updateHeader(with: item)

        let language = item.highlightrLanguage
        currentLoadTask = Task { [weak self] in
            await self?.loadTextFile(at: item.url, language: language)
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

    // MARK: - Header Actions

    /// Animates between collapsed (26px, name + size · kind) and expanded (~108px, with metadata grid).
    @objc private func toggleHeaderExpansion() {
        isHeaderExpanded.toggle()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true

            if isHeaderExpanded {
                headerHeightConstraint.constant = Layout.expandedHeaderHeight
                detailGrid.isHidden = false
                compactDetailLabel.isHidden = true
                disclosureButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Collapse")
            } else {
                headerHeightConstraint.constant = Layout.collapsedHeaderHeight
                detailGrid.isHidden = true
                compactDetailLabel.isHidden = false
                disclosureButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand")
            }

            view.layoutSubtreeIfNeeded()
        }
    }

    /// Copies the file's parent directory path to the clipboard with visual feedback.
    @objc private func copyPathClicked() {
        guard let item = currentItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)

        // Swap to checkmark icon briefly to confirm the copy.
        copyPathButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyPathButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy path")
        }
    }

    // MARK: - Private Helpers

    /// Populates the compact header label and all expanded metadata grid values.
    private func updateHeader(with item: FileItem) {
        headerIconView.image = item.icon
        headerNameLabel.stringValue = item.name
        compactDetailLabel.stringValue = [item.formattedSize, item.kind].joined(separator: " \u{00B7} ")

        sizeValueLabel.stringValue = item.formattedSize
        kindValueLabel.stringValue = item.kind
        createdValueLabel.stringValue = item.creationDate?.fullFormatted ?? "--"
        modifiedValueLabel.stringValue = item.modificationDate?.fullFormatted ?? "--"
        lastOpenedValueLabel.stringValue = item.lastOpenedDate?.fullFormatted ?? "--"
        lockedValueLabel.stringValue = item.isLocked ? "Yes" : "No"
        permissionsValueLabel.stringValue = item.formattedPermissions
        whereValueLabel.stringValue = item.url.path
    }

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

            currentContent = content

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
            textView.string = ""
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

// MARK: - ClickableView

/// Transparent view that forwards mouse clicks to a target/action pair.
private final class ClickableView: NSView {
    private weak var target: AnyObject?
    private let action: Selector

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        _ = target?.perform(action)
    }

}
