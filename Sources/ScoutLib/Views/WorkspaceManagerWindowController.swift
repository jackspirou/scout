import Cocoa

// MARK: - WorkspaceManagerWindowController

/// A window with an NSTableView showing saved workspaces, with Open, Delete, and Close buttons.
final class WorkspaceManagerWindowController: NSWindowController {
    // MARK: - Properties

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private var workspaces: [Workspace] = []
    private var onOpen: ((Workspace) -> Void)?

    // MARK: - Constants

    private enum Layout {
        static let windowWidth: CGFloat = 420
        static let windowHeight: CGFloat = 340
        static let rowHeight: CGFloat = 28
    }

    private static let nameCellID = NSUserInterfaceItemIdentifier("WorkspaceNameCell")
    private static let dateCellID = NSUserInterfaceItemIdentifier("WorkspaceDateCell")

    // MARK: - Initialization

    convenience init(onOpen: @escaping (Workspace) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: Layout.windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manage Workspaces"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.onOpen = onOpen
        setupUI()
        loadWorkspaces()
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Table columns
        let nameColumn = NSTableColumn(identifier: Self.nameCellID)
        nameColumn.title = "Name"
        nameColumn.width = 220
        tableView.addTableColumn(nameColumn)

        let dateColumn = NSTableColumn(identifier: Self.dateCellID)
        dateColumn.title = "Last Used"
        dateColumn.width = 140
        tableView.addTableColumn(dateColumn)

        tableView.rowHeight = Layout.rowHeight
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(openAction(_:))
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        contentView.addSubview(scrollView)

        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(openAction(_:))
        contentView.addSubview(openButton)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteAction(_:))
        contentView.addSubview(deleteButton)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.target = self
        closeButton.action = #selector(closeAction(_:))
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -12),

            closeButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            deleteButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),
            deleteButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            openButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            openButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Data Loading

    private func loadWorkspaces() {
        Task { @MainActor in
            workspaces = await PersistenceService.shared.listWorkspaces()
            tableView.reloadData()
        }
    }

    // MARK: - Date Formatter

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Actions

    @objc private func openAction(_ sender: Any?) {
        let row = tableView.selectedRow
        guard workspaces.indices.contains(row) else { return }
        let workspace = workspaces[row]
        close()
        onOpen?(workspace)
    }

    @objc private func deleteAction(_ sender: Any?) {
        let row = tableView.selectedRow
        guard workspaces.indices.contains(row) else { return }
        let workspace = workspaces[row]
        Task { @MainActor in
            await PersistenceService.shared.deleteWorkspace(id: workspace.id)
            workspaces.remove(at: row)
            tableView.reloadData()
        }
    }

    @objc private func closeAction(_ sender: Any?) {
        close()
    }
}

// MARK: - NSTableViewDataSource

extension WorkspaceManagerWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        workspaces.count
    }
}

// MARK: - NSTableViewDelegate

extension WorkspaceManagerWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard workspaces.indices.contains(row) else { return nil }
        let workspace = workspaces[row]

        let identifier = tableColumn?.identifier ?? Self.nameCellID
        let cell: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        if identifier == Self.nameCellID {
            cell.textField?.stringValue = workspace.name
        } else {
            cell.textField?.stringValue = Self.dateFormatter.string(from: workspace.lastUsedAt)
            cell.textField?.font = NSFont.systemFont(ofSize: 11)
            cell.textField?.textColor = .secondaryLabelColor
        }

        return cell
    }
}
