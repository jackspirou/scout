import AppKit

// MARK: - GetInfoWindowController

/// A native Get Info panel that displays file metadata.
/// Each instance is independent; multiple windows can be open simultaneously.
final class GetInfoWindowController: NSWindowController {
    // MARK: - Initialization

    convenience init(url: URL) {
        let viewController = GetInfoViewController(url: url)
        let window = NSWindow(contentViewController: viewController)
        window.title = "\(url.lastPathComponent) Info"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 350, height: 450))
        window.center()

        self.init(window: window)
    }

    convenience init(fileItem: FileItem) {
        self.init(url: fileItem.url)
    }
}

// MARK: - GetInfoViewController

/// Content view controller for the Get Info window.
private final class GetInfoViewController: NSViewController {
    private var url: URL

    private var permissionsEditorVC: PermissionsEditorViewController?
    private var permissionsContainerView: NSView?
    private var permissionsDisclosed = false

    private var lockedCheckbox: NSButton?

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 450))
        view.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        buildContent(in: stack)

        scrollView.documentView = stack
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])
    }

    // MARK: - Content

    private func buildContent(in stack: NSStackView) {
        let resourceKeys: Set<URLResourceKey> = [
            .nameKey,
            .localizedTypeDescriptionKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .isDirectoryKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]

        let values = try? url.resourceValues(forKeys: resourceKeys)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)

        // File icon (64x64)
        let iconView = NSImageView()
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])
        stack.addArrangedSubview(iconView)

        // Name (editable)
        let nameField = NSTextField(string: values?.name ?? url.lastPathComponent)
        nameField.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        nameField.alignment = .center
        nameField.isBordered = true
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.bezelStyle = .roundedBezel
        nameField.target = self
        nameField.action = #selector(nameEdited(_:))
        nameField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        stack.addArrangedSubview(nameField)

        // Separator
        stack.addArrangedSubview(makeSeparator())

        // Info grid
        let gridView = NSGridView(views: buildInfoRows(values: values, attrs: attrs))
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.rowSpacing = 8
        gridView.columnSpacing = 8
        gridView.column(at: 0).xPlacement = .trailing
        gridView.column(at: 1).xPlacement = .leading
        stack.addArrangedSubview(gridView)

        // Permissions section
        buildPermissionsSection(in: stack, attrs: attrs)

        // Locked checkbox section
        buildLockedSection(in: stack)
    }

    private func buildInfoRows(
        values: URLResourceValues?,
        attrs: [FileAttributeKey: Any]?
    ) -> [[NSView]] {
        var rows: [[NSView]] = []

        // Kind
        let kind = values?.localizedTypeDescription ?? "Unknown"
        rows.append([makeLabel("Kind:"), makeValue(kind)])

        // Size
        let isDirectory = values?.isDirectory ?? false
        if !isDirectory {
            let bytes = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let humanReadable = formatter.string(fromByteCount: bytes)
            let sizeString = "\(humanReadable) (\(bytes) bytes)"
            rows.append([makeLabel("Size:"), makeValue(sizeString)])
        }

        // Location
        let parentPath = url.deletingLastPathComponent().path
        rows.append([makeLabel("Location:"), makeValue(parentPath)])

        // Created date
        if let created = values?.creationDate {
            rows.append([makeLabel("Created:"), makeValue(formatDate(created))])
        }

        // Modified date
        if let modified = values?.contentModificationDate {
            rows.append([makeLabel("Modified:"), makeValue(formatDate(modified))])
        }

        // Permissions
        if let posix = attrs?[.posixPermissions] as? UInt16 {
            let permString = posix.unixPermissionString
            let ownerPart = String(permString.prefix(3))
            let groupPart = String(permString.dropFirst(3).prefix(3))
            let otherPart = String(permString.suffix(3))
            let display = "\(permString) (owner: \(ownerPart), group: \(groupPart), other: \(otherPart))"
            rows.append([makeLabel("Permissions:"), makeValue(display)])
        }

        return rows
    }

    // MARK: - Permissions Section

    private func buildPermissionsSection(in stack: NSStackView, attrs: [FileAttributeKey: Any]?) {
        // Separator
        stack.addArrangedSubview(makeSeparator())

        // Disclosure button
        let disclosureButton = NSButton()
        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.bezelStyle = .disclosure
        disclosureButton.title = ""
        disclosureButton.target = self
        disclosureButton.action = #selector(togglePermissionsDisclosure(_:))
        disclosureButton.state = .off

        let disclosureRow = NSStackView(views: [disclosureButton, makeLabel("Permissions")])
        disclosureRow.orientation = .horizontal
        disclosureRow.spacing = 4
        disclosureRow.alignment = .centerY
        stack.addArrangedSubview(disclosureRow)

        // Permissions editor container (initially hidden)
        let permissions = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let editorVC = PermissionsEditorViewController(url: url, permissions: permissions)
        permissionsEditorVC = editorVC

        addChild(editorVC)
        let containerView = editorVC.view
        containerView.isHidden = true
        stack.addArrangedSubview(containerView)
        permissionsContainerView = containerView
    }

    @objc private func togglePermissionsDisclosure(_ sender: NSButton) {
        permissionsDisclosed = sender.state == .on
        permissionsContainerView?.isHidden = !permissionsDisclosed
    }

    // MARK: - Locked Section

    private func buildLockedSection(in stack: NSStackView) {
        let isLocked = (try? url.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable ?? false

        let checkbox = NSButton(checkboxWithTitle: "Locked", target: self, action: #selector(lockedToggled(_:)))
        checkbox.state = isLocked ? .on : .off
        lockedCheckbox = checkbox

        stack.addArrangedSubview(checkbox)
    }

    @objc private func lockedToggled(_ sender: NSButton) {
        do {
            try (url as NSURL).setResourceValue(sender.state == .on, forKey: .isUserImmutableKey)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            // Revert
            sender.state = (sender.state == .on) ? .off : .on
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func makeValue(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: 12)
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        return field
    }

    private func makeSeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Actions

    @objc private func nameEdited(_ sender: NSTextField) {
        let newName = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            // Revert to original name
            sender.stringValue = url.lastPathComponent
            return
        }

        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard newURL != url else { return }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            // Update stored URL after successful rename
            url = newURL
            // Update permissions editor URL
            permissionsEditorVC?.updateURL(newURL)
            // Update window title
            view.window?.title = "\(newName) Info"
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            sender.stringValue = url.lastPathComponent
        }
    }
}
