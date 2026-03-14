import AppKit
import Foundation

/// Window controller for the "Connect to Server" dialog.
/// Allows the user to enter a server URL (smb, afp, nfs, vnc, ftp) and connect,
/// with a table of recent servers for quick access.
final class ConnectToServerWindowController: NSWindowController {
    // MARK: - UI Elements

    private let urlTextField = NSTextField()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    // MARK: - Data

    private var recentServers: [String] = []

    /// Supported URL schemes for server connections.
    private static let supportedSchemes: Set<String> = ["smb", "afp", "nfs", "vnc", "ftp"]

    /// Maximum number of recent servers to store.
    private static let maxRecentServers = 20

    // MARK: - Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Connect to Server"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
        loadRecentServers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // URL text field
        urlTextField.placeholderString = "smb://server.local/share"
        urlTextField.translatesAutoresizingMaskIntoConstraints = false
        urlTextField.delegate = self
        contentView.addSubview(urlTextField)

        // Connect button
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectAction(_:))
        contentView.addSubview(connectButton)

        // Cancel button
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction(_:))
        contentView.addSubview(cancelButton)

        // Recent servers label
        let label = NSTextField(labelWithString: "Recent Servers:")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        contentView.addSubview(label)

        // Table view for recent servers
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ServerColumn"))
        column.title = "Server"
        column.width = 360
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(tableDoubleClick(_:))
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            // URL field
            urlTextField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            urlTextField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            urlTextField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // Label
            label.topAnchor.constraint(equalTo: urlTextField.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            // Scroll view (table)
            scrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: connectButton.topAnchor, constant: -12),

            // Cancel button
            cancelButton.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            // Connect button
            connectButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            connectButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Actions

    @objc private func connectAction(_ sender: Any?) {
        let urlString = urlTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = validateAndParseURL(urlString) else {
            showInvalidURLAlert()
            return
        }
        connectToServer(url: url, urlString: urlString)
    }

    @objc private func cancelAction(_ sender: Any?) {
        close()
    }

    @objc private func tableDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard recentServers.indices.contains(row) else { return }
        let urlString = recentServers[row]
        guard let url = validateAndParseURL(urlString) else { return }
        connectToServer(url: url, urlString: urlString)
    }

    // MARK: - Connection

    private func connectToServer(url: URL, urlString: String) {
        NSWorkspace.shared.open(url)
        addToRecentServers(urlString)
        close()
    }

    // MARK: - Validation

    private func validateAndParseURL(_ urlString: String) -> URL? {
        guard !urlString.isEmpty,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              Self.supportedSchemes.contains(scheme)
        else {
            return nil
        }
        return url
    }

    private func showInvalidURLAlert() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Invalid Server URL"
        alert.informativeText = "Please enter a valid server URL with a supported scheme (smb, afp, nfs, vnc, ftp)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: - Recent Servers

    private func loadRecentServers() {
        recentServers = PersistenceService.shared.loadRecentServers()
        tableView.reloadData()
    }

    private func addToRecentServers(_ urlString: String) {
        recentServers.removeAll { $0 == urlString }
        recentServers.insert(urlString, at: 0)
        if recentServers.count > Self.maxRecentServers {
            recentServers = Array(recentServers.prefix(Self.maxRecentServers))
        }
        PersistenceService.shared.saveRecentServers(recentServers)
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDataSource

extension ConnectToServerWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        recentServers.count
    }
}

// MARK: - NSTableViewDelegate

extension ConnectToServerWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard recentServers.indices.contains(row) else { return nil }

        let cellIdentifier = NSUserInterfaceItemIdentifier("ServerCell")
        let cell: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier

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

        cell.textField?.stringValue = recentServers[row]
        return cell
    }
}

// MARK: - NSTextFieldDelegate

extension ConnectToServerWindowController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            connectAction(nil)
            return true
        }
        return false
    }
}
