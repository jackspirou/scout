import AppKit

// MARK: - PermissionsEditorViewController

/// Displays a 3x3 grid of permission checkboxes (Owner/Group/Other x Read/Write/Execute)
/// and an octal label. Changes are applied immediately to the file system.
final class PermissionsEditorViewController: NSViewController {
    // MARK: - Properties

    private var url: URL
    private var permissions: UInt16
    private let readOnly: Bool

    // Checkboxes indexed as [row][col] where row=0 is Owner, col=0 is Read
    private var checkboxes: [[NSButton]] = []
    private let octalLabel = NSTextField(labelWithString: "")

    // MARK: - Permission Bit Layout

    // Each entry is (row, col, bit)
    private static let bitMap: [(Int, Int, UInt16)] = [
        (0, 0, 0o400), (0, 1, 0o200), (0, 2, 0o100), // Owner: r, w, x
        (1, 0, 0o040), (1, 1, 0o020), (1, 2, 0o010), // Group: r, w, x
        (2, 0, 0o004), (2, 1, 0o002), (2, 2, 0o001), // Other: r, w, x
    ]

    // MARK: - Initialization

    init(url: URL, permissions: UInt16) {
        self.url = url
        self.permissions = permissions

        // Check if the file itself is writable by the current user
        self.readOnly = !FileManager.default.isWritableFile(atPath: url.path)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let rowLabels = ["Owner", "Group", "Other"]
        let colLabels = ["Read", "Write", "Execute"]

        // Build header row
        var headerViews: [NSView] = [NSView()] // empty top-left cell
        for colLabel in colLabels {
            let label = NSTextField(labelWithString: colLabel)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.alignment = .center
            headerViews.append(label)
        }

        // Build checkbox rows
        var allRows: [[NSView]] = [headerViews]
        checkboxes = []

        for (rowIndex, rowLabel) in rowLabels.enumerated() {
            let label = NSTextField(labelWithString: rowLabel)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.alignment = .right

            var rowViews: [NSView] = [label]
            var rowCheckboxes: [NSButton] = []

            for colIndex in 0..<3 {
                let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxChanged(_:)))
                checkbox.tag = rowIndex * 3 + colIndex
                checkbox.isEnabled = !readOnly

                // Set initial state from permission bits
                let bitIndex = rowIndex * 3 + colIndex
                let bit = Self.bitMap[bitIndex].2
                checkbox.state = (permissions & bit != 0) ? .on : .off

                rowViews.append(checkbox)
                rowCheckboxes.append(checkbox)
            }

            allRows.append(rowViews)
            checkboxes.append(rowCheckboxes)
        }

        let gridView = NSGridView(views: allRows)
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.rowSpacing = 6
        gridView.columnSpacing = 12
        gridView.column(at: 0).xPlacement = .trailing

        // Center the checkboxes in their cells
        for colIdx in 1...3 {
            gridView.column(at: colIdx).xPlacement = .center
        }

        container.addSubview(gridView)

        // Octal label
        octalLabel.translatesAutoresizingMaskIntoConstraints = false
        octalLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        octalLabel.textColor = .secondaryLabelColor
        updateOctalLabel()
        container.addSubview(octalLabel)

        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            gridView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gridView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            octalLabel.topAnchor.constraint(equalTo: gridView.bottomAnchor, constant: 8),
            octalLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            octalLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        view = container
    }

    // MARK: - Actions

    @objc private func checkboxChanged(_ sender: NSButton) {
        let newPermissions = computePermissions()
        permissions = newPermissions
        updateOctalLabel()

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: newPermissions)],
                ofItemAtPath: url.path
            )
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            // Revert checkbox to previous state
            sender.state = (sender.state == .on) ? .off : .on
            permissions = computePermissions()
            updateOctalLabel()
        }
    }

    // MARK: - Helpers

    private func computePermissions() -> UInt16 {
        var result: UInt16 = 0
        for (row, col, bit) in Self.bitMap {
            if checkboxes[row][col].state == .on {
                result |= bit
            }
        }
        return result
    }

    private func updateOctalLabel() {
        let octal = String(permissions, radix: 8)
        let padded = String(repeating: "0", count: max(0, 3 - octal.count)) + octal
        octalLabel.stringValue = "Permissions: \(padded)"
    }

    /// Updates the URL when the file is renamed externally.
    func updateURL(_ newURL: URL) {
        url = newURL
    }
}
