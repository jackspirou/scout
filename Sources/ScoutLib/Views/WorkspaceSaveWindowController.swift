import Cocoa

// MARK: - WorkspaceSaveWindowController

/// A simple panel with a text field for entering a workspace name, plus Save and Cancel buttons.
final class WorkspaceSaveWindowController: NSWindowController {
    // MARK: - Properties

    private let nameField = NSTextField()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var onSave: ((String) -> Void)?

    // MARK: - Constants

    private enum Layout {
        static let windowWidth: CGFloat = 360
        static let windowHeight: CGFloat = 120
    }

    // MARK: - Initialization

    convenience init(onSave: @escaping (String) -> Void) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: Layout.windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Save Workspace"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.onSave = onSave
        setupUI()
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

        let label = NSTextField(labelWithString: "Workspace Name:")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(label)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "My Workspace"
        nameField.delegate = self
        contentView.addSubview(nameField)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveAction(_:))
        contentView.addSubview(saveButton)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction(_:))
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            nameField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Presentation

    /// Shows the save panel centered on the given window.
    func showPanel(relativeTo parentWindow: NSWindow?) {
        guard let panel = window else { return }

        nameField.stringValue = ""

        if let parentFrame = parentWindow?.frame ?? NSScreen.main?.visibleFrame {
            let panelSize = panel.frame.size
            let x = parentFrame.midX - panelSize.width / 2
            let y = parentFrame.midY + panelSize.height / 2
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nameField)
    }

    // MARK: - Actions

    @objc private func saveAction(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        window?.orderOut(nil)
        onSave?(name)
    }

    @objc private func cancelAction(_ sender: Any?) {
        window?.orderOut(nil)
    }
}

// MARK: - NSTextFieldDelegate

extension WorkspaceSaveWindowController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            saveAction(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelAction(nil)
            return true
        }
        return false
    }
}
