import Cocoa

// MARK: - TransferHUDWindowController

/// A floating HUD window that displays active file transfer progress.
///
/// The controller manages an ``NSPanel`` styled as a HUD utility window.
/// Each active ``TransferOperation`` is rendered as a row in an embedded
/// ``NSTableView`` showing filename, progress bar, speed, ETA, and
/// pause/cancel controls.
///
/// The HUD auto-shows when the first transfer is added and auto-hides
/// once all transfers have been removed.
final class TransferHUDWindowController: NSWindowController {
    // MARK: - Properties

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let clearButton = NSButton()

    private var operations: [TransferOperation] = []

    private var autoHideTimer: Timer?

    // MARK: - Constants

    private enum Layout {
        static let windowWidth: CGFloat = 380
        static let windowHeight: CGFloat = 300
        static let rowHeight: CGFloat = 64
        static let bottomBarHeight: CGFloat = 32
    }

    // MARK: - Cell Identifiers

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("TransferCell")

    // MARK: - Formatters

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let timeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    // MARK: - Initialization

    convenience init() {
        let panel = Self.makePanel()
        self.init(window: panel)
        configureContent()
    }

    // MARK: - Panel Factory

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: Layout.windowHeight),
            styleMask: [.titled, .closable, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Transfers"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow

        // Position at bottom-right of screen.
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - Layout.windowWidth - 20
            let y = screenFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        return panel
    }

    // MARK: - Content Configuration

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        configureTableView()
        configureScrollView(in: contentView)
        configureClearButton(in: contentView)
        layoutContent(in: contentView)
    }

    private func configureTableView() {
        tableView.headerView = nil
        tableView.rowHeight = Layout.rowHeight
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.delegate = self
        tableView.dataSource = self
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.usesAlternatingRowBackgroundColors = false

        let column = NSTableColumn(identifier: Self.cellIdentifier)
        column.title = ""
        tableView.addTableColumn(column)
    }

    private func configureScrollView(in contentView: NSView) {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
    }

    private func configureClearButton(in contentView: NSView) {
        clearButton.title = "Clear Completed"
        clearButton.bezelStyle = .recessed
        clearButton.font = NSFont.systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearCompleted(_:))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(clearButton)
    }

    private func layoutContent(in contentView: NSView) {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -4),

            clearButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            clearButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            clearButton.heightAnchor.constraint(equalToConstant: Layout.bottomBarHeight),
        ])
    }

    // MARK: - Public API

    /// Adds a transfer and auto-shows the HUD if it is not already visible.
    func addTransfer(_ operation: TransferOperation) {
        operations.append(operation)
        tableView.reloadData()
        show()
    }

    /// Removes the transfer identified by the given UUID. Auto-hides when empty.
    func removeTransfer(_ id: UUID) {
        operations.removeAll { $0.id == id }
        tableView.reloadData()
        hideIfEmpty()
    }

    /// Shows the HUD panel.
    func show() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil

        if !(window?.isVisible ?? false) {
            window?.orderFront(nil)
        }
    }

    /// Hides the HUD panel.
    func hide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        window?.orderOut(nil)
    }

    /// Reloads the display for all operations (e.g., after progress updates).
    func reloadOperations() {
        tableView.reloadData()
        hideIfEmpty()
    }

    /// Updates a specific operation's row without reloading the entire table.
    func reloadOperation(_ operation: TransferOperation) {
        guard let index = operations.firstIndex(where: { $0.id == operation.id }) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        hideIfEmpty()
    }

    // MARK: - Auto Hide

    private func hideIfEmpty() {
        guard operations.isEmpty else { return }
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.window?.orderOut(nil)
        }
    }

    // MARK: - Actions

    @objc private func clearCompleted(_ sender: Any?) {
        operations.removeAll { isFinished($0) }
        tableView.reloadData()

        if operations.isEmpty {
            window?.orderOut(nil)
        }
    }

    @MainActor
    @objc private func pauseResumeClicked(_ sender: NSButton) {
        let row = sender.tag
        guard operations.indices.contains(row) else { return }
        let operation = operations[row]

        switch operation.status {
        case .inProgress:
            operation.status = .paused
        case .paused:
            operation.status = .inProgress
        default:
            break
        }

        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    @MainActor
    @objc private func cancelClicked(_ sender: NSButton) {
        let row = sender.tag
        guard operations.indices.contains(row) else { return }
        let operation = operations[row]
        operation.status = .cancelled
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        hideIfEmpty()
    }

    // MARK: - Helpers

    @MainActor
    private func isFinished(_ operation: TransferOperation) -> Bool {
        switch operation.status {
        case .completed, .failed, .cancelled:
            return true
        case .pending, .inProgress, .paused:
            return false
        }
    }
}

// MARK: - NSTableViewDataSource

extension TransferHUDWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        operations.count
    }
}

// MARK: - NSTableViewDelegate

extension TransferHUDWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard operations.indices.contains(row) else { return nil }
        let operation = operations[row]

        let cell: NSView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) {
            cell = reused
        } else {
            cell = makeTransferCell()
        }

        configureTransferCell(cell, with: operation, row: row)
        return cell
    }

    // MARK: - Cell Construction

    private func makeTransferCell() -> NSView {
        let cell = NSView()
        cell.identifier = Self.cellIdentifier

        // File icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.tag = 1
        cell.addSubview(iconView)

        // Filename label
        let nameLabel = NSTextField(labelWithString: "")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.tag = 2
        cell.addSubview(nameLabel)

        // Progress bar
        let progressBar = NSProgressIndicator()
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isIndeterminate = false
        progressBar.identifier = NSUserInterfaceItemIdentifier("progressBar")
        cell.addSubview(progressBar)

        // Speed label
        let speedLabel = NSTextField(labelWithString: "")
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        speedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.lineBreakMode = .byTruncatingTail
        speedLabel.tag = 4
        cell.addSubview(speedLabel)

        // ETA label
        let etaLabel = NSTextField(labelWithString: "")
        etaLabel.translatesAutoresizingMaskIntoConstraints = false
        etaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        etaLabel.textColor = .secondaryLabelColor
        etaLabel.alignment = .right
        etaLabel.lineBreakMode = .byTruncatingTail
        etaLabel.tag = 7
        cell.addSubview(etaLabel)

        // Pause/Resume button
        let pauseButton = NSButton(
            image: NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")!,
            target: self,
            action: #selector(pauseResumeClicked(_:))
        )
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.isBordered = false
        pauseButton.tag = 5
        cell.addSubview(pauseButton)

        // Cancel button
        let cancelButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancel")!,
            target: self,
            action: #selector(cancelClicked(_:))
        )
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isBordered = false
        cancelButton.contentTintColor = .systemRed
        cancelButton.tag = 6
        cell.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            iconView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -8),

            progressBar.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            progressBar.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            progressBar.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -8),

            speedLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            speedLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 2),

            etaLabel.leadingAnchor.constraint(equalTo: speedLabel.trailingAnchor, constant: 4),
            etaLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 2),
            etaLabel.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -8),

            pauseButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -4),
            pauseButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            pauseButton.widthAnchor.constraint(equalToConstant: 24),
            pauseButton.heightAnchor.constraint(equalToConstant: 24),

            cancelButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 24),
            cancelButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        return cell
    }

    @MainActor
    private func configureTransferCell(_ cell: NSView, with operation: TransferOperation, row: Int) {
        let iconView = cell.viewWithTag(1) as? NSImageView
        let nameLabel = cell.viewWithTag(2) as? NSTextField
        let progressBar = cell.subviews
            .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("progressBar") }) as? NSProgressIndicator
        let speedLabel = cell.viewWithTag(4) as? NSTextField
        let pauseButton = cell.viewWithTag(5) as? NSButton
        let cancelButton = cell.viewWithTag(6) as? NSButton
        let etaLabel = cell.viewWithTag(7) as? NSTextField

        // Icon - use the first source URL for icon lookup.
        if let firstSource = operation.sourceURLs.first {
            iconView?.image = NSWorkspace.shared.icon(forFile: firstSource.path)
        }

        // Filename - show the first source file name; append count for multi-file transfers.
        if operation.sourceURLs.count == 1, let firstSource = operation.sourceURLs.first {
            nameLabel?.stringValue = firstSource.lastPathComponent
        } else {
            nameLabel?.stringValue = "\(operation.sourceURLs.count) items"
        }

        // Progress fraction
        let fraction: Double
        if operation.totalBytes > 0 {
            fraction = Double(operation.bytesTransferred) / Double(operation.totalBytes)
        } else {
            fraction = 0
        }
        progressBar?.doubleValue = fraction

        // Speed label
        speedLabel?.stringValue = speedText(for: operation)

        // ETA label
        etaLabel?.stringValue = etaText(for: operation)

        // Button visibility and state
        pauseButton?.tag = row
        cancelButton?.tag = row

        switch operation.status {
        case .inProgress:
            pauseButton?.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
            pauseButton?.isEnabled = true
            cancelButton?.isEnabled = true
        case .paused:
            pauseButton?.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Resume")
            pauseButton?.isEnabled = true
            cancelButton?.isEnabled = true
        case .pending:
            pauseButton?.isEnabled = false
            cancelButton?.isEnabled = true
        case .completed:
            pauseButton?.isEnabled = false
            cancelButton?.isEnabled = false
            progressBar?.doubleValue = 1.0
        case .failed, .cancelled:
            pauseButton?.isEnabled = false
            cancelButton?.isEnabled = false
        }
    }

    // MARK: - Status Formatting

    @MainActor
    private func speedText(for operation: TransferOperation) -> String {
        switch operation.status {
        case .inProgress:
            return operation.formattedSpeed
        case .paused:
            return "Paused"
        case .pending:
            return "Queued"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    @MainActor
    private func etaText(for operation: TransferOperation) -> String {
        switch operation.status {
        case .inProgress:
            if let eta = operation.estimatedTimeRemaining,
               let formatted = Self.timeFormatter.string(from: eta)
            {
                return "\(formatted) remaining"
            }
            return ""
        case .paused:
            let transferred = Self.byteFormatter.string(fromByteCount: operation.bytesTransferred)
            let total = Self.byteFormatter.string(fromByteCount: operation.totalBytes)
            return "\(transferred) of \(total)"
        default:
            return ""
        }
    }
}
