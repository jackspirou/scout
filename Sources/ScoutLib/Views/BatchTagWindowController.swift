import Cocoa

// MARK: - BatchTagWindowController

/// A modal window for batch-applying macOS tags to multiple files.
final class BatchTagWindowController: NSWindowController {
    private let fileURLs: [URL]
    private var existingTags: [[String]] = []

    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var tagCheckboxes: [(checkbox: NSButton, tagName: String, color: NSColor)] = []
    private let customTagField = NSTextField()
    private let addCustomButton = NSButton(title: "Add", target: nil, action: nil)
    private var customTags: [String] = []

    private let previewTable = NSTableView()
    private let scrollView = NSScrollView()

    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    var onComplete: (() -> Void)?

    // MARK: - Initialization

    init(fileURLs: [URL]) {
        self.fileURLs = fileURLs

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tag Files (\(fileURLs.count) selected)"
        window.minSize = NSSize(width: 420, height: 380)
        window.center()

        super.init(window: window)

        loadExistingTags()
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func loadExistingTags() {
        existingTags = fileURLs.map { url in
            (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        }
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Mode selector row
        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        let modeLabel = NSTextField(labelWithString: "Mode:")
        modePopup.addItems(withTitles: ["Add Tags", "Remove Tags", "Set Tags"])
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modeRow.addArrangedSubview(modeLabel)
        modeRow.addArrangedSubview(modePopup)
        mainStack.addArrangedSubview(modeRow)

        // System tag checkboxes
        let tagGrid = buildSystemTagGrid()
        mainStack.addArrangedSubview(tagGrid)

        // Custom tag row
        let customRow = NSStackView()
        customRow.orientation = .horizontal
        customRow.spacing = 8
        let customLabel = NSTextField(labelWithString: "Custom:")
        customTagField.placeholderString = "Tag name"
        customTagField.translatesAutoresizingMaskIntoConstraints = false
        customTagField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        addCustomButton.target = self
        addCustomButton.action = #selector(addCustomTag(_:))
        addCustomButton.bezelStyle = .rounded
        customRow.addArrangedSubview(customLabel)
        customRow.addArrangedSubview(customTagField)
        customRow.addArrangedSubview(addCustomButton)
        mainStack.addArrangedSubview(customRow)

        // Preview table
        setupPreviewTable()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        mainStack.addArrangedSubview(scrollView)

        // Buttons
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        applyButton.target = self
        applyButton.action = #selector(applyClicked(_:))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(applyButton)
        mainStack.addArrangedSubview(buttonRow)

        updatePreview()
    }

    private func buildSystemTagGrid() -> NSView {
        let labels = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 6
        grid.alignment = .leading

        var row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        for i in 0 ..< min(labels.count, colors.count) {
            let name = labels[i]
            guard !name.isEmpty else { continue }
            let color = colors[i]

            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(tagCheckboxChanged(_:)))
            checkbox.tag = tagCheckboxes.count

            // Color dot + label
            let dot = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            dot.layer?.backgroundColor = color.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true

            let label = NSTextField(labelWithString: name)
            label.font = NSFont.systemFont(ofSize: 12)

            let item = NSStackView(views: [checkbox, dot, label])
            item.orientation = .horizontal
            item.spacing = 4

            tagCheckboxes.append((checkbox: checkbox, tagName: name, color: color))

            row.addArrangedSubview(item)

            // 3 tags per row
            if row.arrangedSubviews.count >= 3 {
                grid.addArrangedSubview(row)
                row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 12
            }
        }

        if !row.arrangedSubviews.isEmpty {
            grid.addArrangedSubview(row)
        }

        return grid
    }

    private func setupPreviewTable() {
        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        fileColumn.title = "File"
        fileColumn.width = 200
        previewTable.addTableColumn(fileColumn)

        let tagsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ResultTagsColumn"))
        tagsColumn.title = "Result Tags"
        tagsColumn.width = 250
        previewTable.addTableColumn(tagsColumn)

        previewTable.dataSource = self
        previewTable.delegate = self
        previewTable.usesAlternatingRowBackgroundColors = true
        previewTable.headerView = NSTableHeaderView()

        scrollView.documentView = previewTable
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }

    // MARK: - Tag Computation

    private func selectedTags() -> [String] {
        var tags: [String] = []
        for entry in tagCheckboxes where entry.checkbox.state == .on {
            tags.append(entry.tagName)
        }
        tags.append(contentsOf: customTags)
        return tags
    }

    private func currentPattern() -> BatchTagPattern {
        let tags = selectedTags()
        switch modePopup.indexOfSelectedItem {
        case 1: return .remove(tags: tags)
        case 2: return .set(tags: tags)
        default: return .add(tags: tags)
        }
    }

    private func resultTags(for index: Int) -> [String] {
        let existing = existingTags[index]
        let tags = selectedTags()

        switch modePopup.indexOfSelectedItem {
        case 1: // Remove
            return existing.filter { !tags.contains($0) }
        case 2: // Set
            return tags
        default: // Add
            var merged = existing
            for tag in tags where !merged.contains(tag) {
                merged.append(tag)
            }
            return merged
        }
    }

    // MARK: - Preview

    private func updatePreview() {
        previewTable.reloadData()
    }

    // MARK: - Actions

    @objc private func modeChanged(_: NSPopUpButton) {
        updatePreview()
    }

    @objc private func tagCheckboxChanged(_: NSButton) {
        updatePreview()
    }

    @objc private func addCustomTag(_: NSButton) {
        let tag = customTagField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !customTags.contains(tag) else { return }
        customTags.append(tag)
        customTagField.stringValue = ""
        updatePreview()
    }

    @objc private func cancelClicked(_: NSButton) {
        close()
    }

    @objc private func applyClicked(_: NSButton) {
        let pattern = currentPattern()

        Task {
            do {
                try await FileSystemService.shared.batchSetTags(urls: fileURLs, pattern: pattern)
                await MainActor.run {
                    self.onComplete?()
                    self.close()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension BatchTagWindowController: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int {
        fileURLs.count
    }
}

// MARK: - NSTableViewDelegate

extension BatchTagWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }

        let identifier = column.identifier
        let cellID = NSUserInterfaceItemIdentifier("TagCell_\(identifier.rawValue)")

        if identifier.rawValue == "FileColumn" {
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
                ?? NSTableCellView()
            cell.identifier = cellID

            if cell.textField == nil {
                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            cell.textField?.stringValue = fileURLs[row].lastPathComponent
            return cell
        }

        // Result Tags column — show colored dots
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) ?? NSView()
        cell.identifier = cellID
        cell.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
        ])

        let result = resultTags(for: row)
        let labels = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors

        for tag in result {
            let color: NSColor
            if let idx = labels.firstIndex(of: tag), idx < colors.count {
                color = colors[idx]
            } else {
                color = .systemGray
            }

            let dot = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            dot.layer?.backgroundColor = color.cgColor
            dot.toolTip = tag
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
            stack.addArrangedSubview(dot)
        }

        return cell
    }
}
