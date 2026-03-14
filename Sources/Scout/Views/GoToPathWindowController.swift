import Cocoa

// MARK: - GoToPathWindowController

final class GoToPathWindowController: NSWindowController {
    // MARK: - Properties

    private let searchField = NSTextField()
    private let resultsTableView = NSTableView()
    private let scrollView = NSScrollView()

    private var currentDirectoryURL: URL
    private var onNavigate: ((URL) -> Void)?
    private var completions: [URL] = []

    // MARK: - Constants

    private enum Layout {
        static let windowWidth: CGFloat = 500
        static let windowHeight: CGFloat = 300
        static let searchFieldHeight: CGFloat = 36
        static let rowHeight: CGFloat = 24
    }

    // MARK: - Cell Identifier

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("GoToPathCell")

    // MARK: - Initialization

    convenience init(currentDirectoryURL: URL, onNavigate: ((URL) -> Void)?) {
        let panel = Self.makePanel()
        self.init(window: panel)
        self.currentDirectoryURL = currentDirectoryURL
        self.onNavigate = onNavigate
        configureContent()
    }

    override init(window: NSWindow?) {
        self.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Panel Factory

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: Layout.windowHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        return panel
    }

    // MARK: - Content Configuration

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        contentView.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        configureSearchField(in: container)
        configureSeparator(in: container)
        configureResultsTable(in: container)
    }

    private func configureSearchField(in container: NSView) {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Enter path or folder name..."
        searchField.font = NSFont.systemFont(ofSize: 16, weight: .light)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.delegate = self
        searchField.cell?.sendsActionOnEndEditing = false
        container.addSubview(searchField)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Path")
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: Layout.searchFieldHeight),
        ])
    }

    private func configureSeparator(in container: NSView) {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func configureResultsTable(in container: NSView) {
        resultsTableView.headerView = nil
        resultsTableView.rowHeight = Layout.rowHeight
        resultsTableView.backgroundColor = .clear
        resultsTableView.selectionHighlightStyle = .regular
        resultsTableView.delegate = self
        resultsTableView.dataSource = self
        resultsTableView.intercellSpacing = NSSize(width: 0, height: 1)
        resultsTableView.target = self
        resultsTableView.doubleAction = #selector(navigateToSelected)

        let column = NSTableColumn(identifier: Self.cellIdentifier)
        column.title = ""
        resultsTableView.addTableColumn(column)

        scrollView.documentView = resultsTableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let topOffset = Layout.searchFieldHeight + 12

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: topOffset),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Presentation

    /// Shows the Go to Path panel centered on the given window (or the main screen).
    func showPanel(relativeTo parentWindow: NSWindow? = nil) {
        guard let panel = window as? NSPanel else { return }

        completions = []
        searchField.stringValue = ""
        resultsTableView.reloadData()

        if let parentFrame = parentWindow?.frame ?? NSScreen.main?.visibleFrame {
            let panelSize = panel.frame.size
            let x = parentFrame.midX - panelSize.width / 2
            let y = parentFrame.midY + panelSize.height / 2
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    /// Dismisses the panel.
    func dismissPanel() {
        window?.orderOut(nil)
    }

    // MARK: - Path Completion

    private func updateCompletions(for input: String) {
        guard !input.isEmpty else {
            completions = []
            resultsTableView.reloadData()
            return
        }

        let resolvedURL: URL
        let searchPrefix: String

        if input.hasPrefix("/") || input.hasPrefix("~") {
            // Absolute path or home-relative path
            let expandedPath = NSString(string: input).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)

            // Check if the path itself is a valid directory
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                // List contents of this directory
                resolvedURL = url
                searchPrefix = ""
            } else {
                // Use the parent directory and filter by the last component
                resolvedURL = url.deletingLastPathComponent()
                searchPrefix = url.lastPathComponent.lowercased()
            }
        } else {
            // Relative path: resolve against current directory
            resolvedURL = currentDirectoryURL
            searchPrefix = input.lowercased()
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: resolvedURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            if searchPrefix.isEmpty {
                // Show all items, directories first
                completions = contents.sorted { lhs, rhs in
                    let lhsIsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let rhsIsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if lhsIsDir != rhsIsDir { return lhsIsDir }
                    return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
                }
            } else {
                completions = contents
                    .filter { $0.lastPathComponent.lowercased().hasPrefix(searchPrefix) }
                    .sorted { lhs, rhs in
                        let lhsIsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        let rhsIsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if lhsIsDir != rhsIsDir { return lhsIsDir }
                        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
                    }
            }
        } catch {
            completions = []
        }

        resultsTableView.reloadData()

        if !completions.isEmpty {
            resultsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Navigation

    @objc private func navigateToSelected() {
        let row = resultsTableView.selectedRow
        guard completions.indices.contains(row) else { return }
        let url = completions[row]
        dismissPanel()
        onNavigate?(url)
    }

    private func navigateToTypedPath() {
        let input = searchField.stringValue
        guard !input.isEmpty else { return }

        let expandedPath = NSString(string: input).expandingTildeInPath
        let url: URL
        if input.hasPrefix("/") || input.hasPrefix("~") {
            url = URL(fileURLWithPath: expandedPath)
        } else {
            url = currentDirectoryURL.appendingPathComponent(input)
        }

        // Verify the path exists
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        dismissPanel()
        onNavigate?(url)
    }
}

// MARK: - NSTextFieldDelegate

extension GoToPathWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateCompletions(for: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelectionUp()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelectionDown()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let row = resultsTableView.selectedRow
            if completions.indices.contains(row) {
                navigateToSelected()
            } else {
                navigateToTypedPath()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissPanel()
            return true
        default:
            return false
        }
    }

    private func moveSelectionUp() {
        let row = resultsTableView.selectedRow
        guard row > 0 else { return }
        let newRow = row - 1
        resultsTableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        resultsTableView.scrollRowToVisible(newRow)
    }

    private func moveSelectionDown() {
        let row = resultsTableView.selectedRow
        guard row < completions.count - 1 else { return }
        let newRow = row + 1
        resultsTableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        resultsTableView.scrollRowToVisible(newRow)
    }
}

// MARK: - NSTableViewDataSource

extension GoToPathWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        completions.count
    }
}

// MARK: - NSTableViewDelegate

extension GoToPathWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard completions.indices.contains(row) else { return nil }
        let url = completions[row]

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = makePathCell()
        }

        cell.textField?.stringValue = url.lastPathComponent

        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let symbolName = isDir ? "folder" : "doc"
        cell.imageView?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)

        // Set the detail label with the full path
        if let detailLabel = cell.viewWithTag(101) as? NSTextField {
            detailLabel.stringValue = url.path
        }

        return cell
    }

    private func makePathCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellIdentifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        let detailLabel = NSTextField(labelWithString: "")
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.alignment = .right
        detailLabel.tag = 101
        cell.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8),

            detailLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])

        return cell
    }
}
