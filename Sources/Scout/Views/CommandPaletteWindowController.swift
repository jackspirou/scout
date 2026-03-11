import Cocoa

// MARK: - PaletteAction

/// Represents a single executable action in the command palette.
struct PaletteAction {
    let name: String
    let shortcut: String?
    let icon: NSImage?
    let handler: () -> Void
}

// MARK: - CommandPaletteWindowController

final class CommandPaletteWindowController: NSWindowController {
    // MARK: - Properties

    private let searchField = NSTextField()
    private let resultsTableView = NSTableView()
    private let scrollView = NSScrollView()

    private var allActions: [PaletteAction] = []
    private var filteredActions: [PaletteAction] = []
    private var selectedIndex: Int = 0

    // MARK: - Constants

    private enum Layout {
        static let windowWidth: CGFloat = 500
        static let maxWindowHeight: CGFloat = 400
        static let searchFieldHeight: CGFloat = 40
        static let rowHeight: CGFloat = 32
        static let cornerRadius: CGFloat = 10
        static let maxVisibleRows: Int = 10
    }

    // MARK: - Cell Identifier

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("PaletteCell")

    // MARK: - Initialization

    convenience init(actions: [PaletteAction]) {
        let panel = Self.makePanel()
        self.init(window: panel)
        allActions = actions
        filteredActions = actions
        configureContent()
    }

    // MARK: - Panel Factory

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: Layout.maxWindowHeight),
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

        // Background container with rounded corners
        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = Layout.cornerRadius
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
        searchField.placeholderString = "Type a command..."
        searchField.font = NSFont.systemFont(ofSize: 18, weight: .light)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.delegate = self
        searchField.cell?.sendsActionOnEndEditing = false
        container.addSubview(searchField)

        // Magnifying glass icon
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
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
        resultsTableView.doubleAction = #selector(executeSelectedAction)

        let column = NSTableColumn(identifier: Self.cellIdentifier)
        column.title = ""
        resultsTableView.addTableColumn(column)

        scrollView.documentView = resultsTableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let topOffset = Layout.searchFieldHeight + 12 // search + padding + separator

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: topOffset),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Presentation

    /// Shows the command palette centered on the given window (or the main screen).
    func showPalette(relativeTo parentWindow: NSWindow? = nil) {
        guard let panel = window as? NSPanel else { return }

        filteredActions = allActions
        selectedIndex = 0
        searchField.stringValue = ""
        resultsTableView.reloadData()

        // Size the panel based on visible rows
        updatePanelHeight()

        // Center on parent window or screen
        if let parentFrame = parentWindow?.frame ?? NSScreen.main?.visibleFrame {
            let panelSize = panel.frame.size
            let x = parentFrame.midX - panelSize.width / 2
            let y = parentFrame.midY + panelSize.height / 2 // slightly above center
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    /// Dismisses the command palette.
    func dismissPalette() {
        window?.orderOut(nil)
    }

    // MARK: - Filtering

    private func filterActions(query: String) {
        if query.isEmpty {
            filteredActions = allActions
        } else {
            filteredActions = allActions
                .map { action -> (PaletteAction, Int) in
                    let score = action.name.fuzzyMatchScore(query: query) ?? 0
                    return (action, score)
                }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }

        selectedIndex = 0
        resultsTableView.reloadData()
        updatePanelHeight()

        if !filteredActions.isEmpty {
            resultsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Panel Sizing

    private func updatePanelHeight() {
        let rowCount = min(filteredActions.count, Layout.maxVisibleRows)
        let tableHeight = CGFloat(rowCount) * Layout.rowHeight
        let totalHeight = Layout.searchFieldHeight + 12 + tableHeight + 8

        var frame = window?.frame ?? .zero
        let oldTop = frame.maxY
        frame.size.height = min(totalHeight, Layout.maxWindowHeight)
        frame.origin.y = oldTop - frame.size.height
        window?.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Execution

    @objc private func executeSelectedAction() {
        guard filteredActions.indices.contains(selectedIndex) else { return }
        let action = filteredActions[selectedIndex]
        dismissPalette()
        action.handler()
    }

    // MARK: - Key Navigation

    private func moveSelectionUp() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
        resultsTableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        resultsTableView.scrollRowToVisible(selectedIndex)
    }

    private func moveSelectionDown() {
        guard selectedIndex < filteredActions.count - 1 else { return }
        selectedIndex += 1
        resultsTableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        resultsTableView.scrollRowToVisible(selectedIndex)
    }
}

// MARK: - NSTextFieldDelegate

extension CommandPaletteWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        filterActions(query: searchField.stringValue)
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
            executeSelectedAction()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissPalette()
            return true
        default:
            return false
        }
    }
}

// MARK: - NSTableViewDataSource

extension CommandPaletteWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredActions.count
    }
}

// MARK: - NSTableViewDelegate

extension CommandPaletteWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredActions.indices.contains(row) else { return nil }
        let action = filteredActions[row]

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = makePaletteCell()
        }

        cell.textField?.stringValue = action.name
        cell.imageView?.image = action.icon ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil)

        // Set shortcut label
        if let shortcutLabel = cell.viewWithTag(100) as? NSTextField {
            shortcutLabel.stringValue = action.shortcut ?? ""
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = resultsTableView.selectedRow
        if row >= 0 {
            selectedIndex = row
        }
    }

    private func makePaletteCell() -> NSTableCellView {
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

        let shortcutLabel = NSTextField(labelWithString: "")
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.tag = 100
        cell.addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),

            shortcutLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            shortcutLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            shortcutLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
        ])

        return cell
    }
}
