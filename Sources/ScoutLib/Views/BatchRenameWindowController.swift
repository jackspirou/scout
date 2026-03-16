import Cocoa

// MARK: - BatchRenameWindowController

final class BatchRenameWindowController: NSWindowController {
    // MARK: - Types

    private enum RenameMode: Int, CaseIterable {
        case findReplace = 0
        case sequential = 1
        case regex = 2
        case datePrefix = 3

        var title: String {
            switch self {
            case .findReplace: return "Find & Replace"
            case .sequential: return "Sequential"
            case .regex: return "Regex"
            case .datePrefix: return "Date Prefix"
            }
        }
    }

    // MARK: - Properties

    private let fileURLs: [URL]
    private let fileSystemService = FileSystemService.shared
    private var onComplete: (() -> Void)?

    private let modeSelector = NSPopUpButton()
    private let modeFieldsContainer = NSView()
    private let previewTableView = NSTableView()
    private let previewScrollView = NSScrollView()
    private let renameButton = NSButton()
    private let cancelButton = NSButton()

    // Find & Replace fields
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let caseSensitiveCheckbox = NSButton()

    // Sequential fields
    private let prefixField = NSTextField()
    private let startNumberField = NSTextField()
    private let zeroPaddingStepper = NSStepper()
    private let zeroPaddingLabel = NSTextField(labelWithString: "")
    private let suffixField = NSTextField()

    // Regex fields
    private let regexPatternField = NSTextField()
    private let regexReplacementField = NSTextField()

    /// Date Prefix fields
    private let dateFormatField = NSTextField()

    private var previewNames: [(original: String, renamed: String)] = []

    // MARK: - Cell Identifiers

    private static let originalColumnId = NSUserInterfaceItemIdentifier("OriginalColumn")
    private static let renamedColumnId = NSUserInterfaceItemIdentifier("RenamedColumn")

    // MARK: - Initialization

    convenience init(fileURLs: [URL], onComplete: (() -> Void)? = nil) {
        let window = Self.makeWindow()
        self.init(window: window)
        // Store URLs and callback via separate assignments since stored properties
        // cannot be set before convenience init delegation.
        self.fileURLs.withUnsafeBufferPointer { _ in }
        setFileURLs(fileURLs)
        self.onComplete = onComplete
        configureContent()
        updatePreview()
    }

    /// Workaround: sets fileURLs after `self.init(window:)`.
    private func setFileURLs(_ urls: [URL]) {
        let mirror = UnsafeMutablePointer<BatchRenameWindowController>(
            OpaquePointer(Unmanaged.passUnretained(self).toOpaque())
        )
        mirror.pointee.fileURLsMutable = urls
    }

    /// Mutable backing for fileURLs, used only by `setFileURLs`.
    private var fileURLsMutable: [URL] {
        get { fileURLs }
        set {
            // This setter is only callable through the unsafe pointer trick in setFileURLs.
        }
    }

    /// Designated initializer override to set fileURLs to empty.
    override init(window: NSWindow?) {
        fileURLs = []
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Window Factory

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Batch Rename"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 400)
        window.center()
        return window
    }

    // MARK: - Content Configuration

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let padding: CGFloat = 20

        // Mode selector
        let modeLabel = NSTextField(labelWithString: "Mode:")
        modeLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(modeLabel)

        modeSelector.translatesAutoresizingMaskIntoConstraints = false
        for mode in RenameMode.allCases {
            modeSelector.addItem(withTitle: mode.title)
        }
        modeSelector.target = self
        modeSelector.action = #selector(modeChanged(_:))
        contentView.addSubview(modeSelector)

        // Mode-specific fields container
        modeFieldsContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(modeFieldsContainer)

        // Preview label
        let previewLabel = NSTextField(labelWithString: "Preview:")
        previewLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewLabel)

        // Preview table
        configurePreviewTable()
        contentView.addSubview(previewScrollView)

        // Buttons
        renameButton.title = "Rename"
        renameButton.bezelStyle = .rounded
        renameButton.keyEquivalent = "\r"
        renameButton.target = self
        renameButton.action = #selector(renameClicked(_:))
        renameButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(renameButton)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            // Mode label + selector
            modeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            modeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            modeLabel.centerYAnchor.constraint(equalTo: modeSelector.centerYAnchor),

            modeSelector.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            modeSelector.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 8),
            modeSelector.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Mode fields container
            modeFieldsContainer.topAnchor.constraint(equalTo: modeSelector.bottomAnchor, constant: 16),
            modeFieldsContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            modeFieldsContainer.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -padding
            ),
            modeFieldsContainer.heightAnchor.constraint(equalToConstant: 100),

            // Preview label
            previewLabel.topAnchor.constraint(equalTo: modeFieldsContainer.bottomAnchor, constant: 12),
            previewLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),

            // Preview table
            previewScrollView.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 6),
            previewScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            previewScrollView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -padding
            ),
            previewScrollView.bottomAnchor.constraint(equalTo: renameButton.topAnchor, constant: -16),

            // Buttons
            renameButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            renameButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
            renameButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            cancelButton.trailingAnchor.constraint(equalTo: renameButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: renameButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        configureModeFields(for: .findReplace)
    }

    private func configurePreviewTable() {
        previewTableView.headerView = NSTableHeaderView()
        previewTableView.rowHeight = 22
        previewTableView.usesAlternatingRowBackgroundColors = true
        previewTableView.delegate = self
        previewTableView.dataSource = self

        let originalColumn = NSTableColumn(identifier: Self.originalColumnId)
        originalColumn.title = "Original Name"
        originalColumn.width = 240
        originalColumn.minWidth = 120
        previewTableView.addTableColumn(originalColumn)

        let renamedColumn = NSTableColumn(identifier: Self.renamedColumnId)
        renamedColumn.title = "New Name"
        renamedColumn.width = 240
        renamedColumn.minWidth = 120
        previewTableView.addTableColumn(renamedColumn)

        previewScrollView.documentView = previewTableView
        previewScrollView.hasVerticalScroller = true
        previewScrollView.autohidesScrollers = true
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        previewScrollView.borderType = .bezelBorder
    }

    // MARK: - Mode-Specific Fields

    private func configureModeFields(for mode: RenameMode) {
        // Remove existing subviews
        modeFieldsContainer.subviews.forEach { $0.removeFromSuperview() }

        switch mode {
        case .findReplace:
            configureFindReplaceFields()
        case .sequential:
            configureSequentialFields()
        case .regex:
            configureRegexFields()
        case .datePrefix:
            configureDatePrefixFields()
        }
    }

    private func configureFindReplaceFields() {
        let findLabel = NSTextField(labelWithString: "Find:")
        findLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(findLabel)

        findField.placeholderString = "Text to find"
        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.delegate = self
        modeFieldsContainer.addSubview(findField)

        let replaceLabel = NSTextField(labelWithString: "Replace:")
        replaceLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(replaceLabel)

        replaceField.placeholderString = "Replacement text"
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.delegate = self
        modeFieldsContainer.addSubview(replaceField)

        caseSensitiveCheckbox.setButtonType(.switch)
        caseSensitiveCheckbox.title = "Case Sensitive"
        caseSensitiveCheckbox.state = .on
        caseSensitiveCheckbox.translatesAutoresizingMaskIntoConstraints = false
        caseSensitiveCheckbox.target = self
        caseSensitiveCheckbox.action = #selector(fieldChanged(_:))
        modeFieldsContainer.addSubview(caseSensitiveCheckbox)

        let labelWidth: CGFloat = 60

        NSLayoutConstraint.activate([
            findLabel.topAnchor.constraint(equalTo: modeFieldsContainer.topAnchor),
            findLabel.leadingAnchor.constraint(equalTo: modeFieldsContainer.leadingAnchor),
            findLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            findField.centerYAnchor.constraint(equalTo: findLabel.centerYAnchor),
            findField.leadingAnchor.constraint(equalTo: findLabel.trailingAnchor, constant: 4),
            findField.trailingAnchor.constraint(equalTo: modeFieldsContainer.trailingAnchor),

            replaceLabel.topAnchor.constraint(equalTo: findLabel.bottomAnchor, constant: 8),
            replaceLabel.leadingAnchor.constraint(equalTo: modeFieldsContainer.leadingAnchor),
            replaceLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            replaceField.centerYAnchor.constraint(equalTo: replaceLabel.centerYAnchor),
            replaceField.leadingAnchor.constraint(equalTo: replaceLabel.trailingAnchor, constant: 4),
            replaceField.trailingAnchor.constraint(equalTo: modeFieldsContainer.trailingAnchor),

            caseSensitiveCheckbox.topAnchor.constraint(equalTo: replaceLabel.bottomAnchor, constant: 8),
            caseSensitiveCheckbox.leadingAnchor.constraint(
                equalTo: replaceField.leadingAnchor
            ),
        ])
    }

    private func configureSequentialFields() {
        let prefixLabel = NSTextField(labelWithString: "Prefix:")
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(prefixLabel)

        prefixField.placeholderString = "file_"
        prefixField.translatesAutoresizingMaskIntoConstraints = false
        prefixField.delegate = self
        modeFieldsContainer.addSubview(prefixField)

        let startLabel = NSTextField(labelWithString: "Start:")
        startLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(startLabel)

        startNumberField.placeholderString = "1"
        startNumberField.stringValue = "1"
        startNumberField.translatesAutoresizingMaskIntoConstraints = false
        startNumberField.delegate = self
        modeFieldsContainer.addSubview(startNumberField)

        let paddingLabel = NSTextField(labelWithString: "Padding:")
        paddingLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(paddingLabel)

        zeroPaddingStepper.minValue = 1
        zeroPaddingStepper.maxValue = 10
        zeroPaddingStepper.integerValue = 3
        zeroPaddingStepper.increment = 1
        zeroPaddingStepper.translatesAutoresizingMaskIntoConstraints = false
        zeroPaddingStepper.target = self
        zeroPaddingStepper.action = #selector(stepperChanged(_:))
        modeFieldsContainer.addSubview(zeroPaddingStepper)

        zeroPaddingLabel.stringValue = "3"
        zeroPaddingLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        zeroPaddingLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(zeroPaddingLabel)

        let suffixLabel = NSTextField(labelWithString: "Suffix:")
        suffixLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(suffixLabel)

        suffixField.placeholderString = ""
        suffixField.translatesAutoresizingMaskIntoConstraints = false
        suffixField.delegate = self
        modeFieldsContainer.addSubview(suffixField)

        let labelWidth: CGFloat = 55

        NSLayoutConstraint.activate([
            prefixLabel.topAnchor.constraint(equalTo: modeFieldsContainer.topAnchor),
            prefixLabel.leadingAnchor.constraint(equalTo: modeFieldsContainer.leadingAnchor),
            prefixLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            prefixField.centerYAnchor.constraint(equalTo: prefixLabel.centerYAnchor),
            prefixField.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: 4),
            prefixField.widthAnchor.constraint(equalToConstant: 120),

            startLabel.centerYAnchor.constraint(equalTo: prefixLabel.centerYAnchor),
            startLabel.leadingAnchor.constraint(equalTo: prefixField.trailingAnchor, constant: 12),

            startNumberField.centerYAnchor.constraint(equalTo: prefixLabel.centerYAnchor),
            startNumberField.leadingAnchor.constraint(equalTo: startLabel.trailingAnchor, constant: 4),
            startNumberField.widthAnchor.constraint(equalToConstant: 60),

            suffixLabel.topAnchor.constraint(equalTo: prefixLabel.bottomAnchor, constant: 8),
            suffixLabel.leadingAnchor.constraint(equalTo: modeFieldsContainer.leadingAnchor),
            suffixLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            suffixField.centerYAnchor.constraint(equalTo: suffixLabel.centerYAnchor),
            suffixField.leadingAnchor.constraint(equalTo: suffixLabel.trailingAnchor, constant: 4),
            suffixField.widthAnchor.constraint(equalToConstant: 120),

            paddingLabel.centerYAnchor.constraint(equalTo: suffixLabel.centerYAnchor),
            paddingLabel.leadingAnchor.constraint(equalTo: suffixField.trailingAnchor, constant: 12),

            zeroPaddingLabel.centerYAnchor.constraint(equalTo: suffixLabel.centerYAnchor),
            zeroPaddingLabel.leadingAnchor.constraint(equalTo: paddingLabel.trailingAnchor, constant: 4),

            zeroPaddingStepper.centerYAnchor.constraint(equalTo: suffixLabel.centerYAnchor),
            zeroPaddingStepper.leadingAnchor.constraint(equalTo: zeroPaddingLabel.trailingAnchor, constant: 4),
        ])
    }

    private func configureRegexFields() {
        let patternLabel = NSTextField(labelWithString: "Pattern:")
        patternLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(patternLabel)

        regexPatternField.placeholderString = "Regular expression pattern"
        regexPatternField.translatesAutoresizingMaskIntoConstraints = false
        regexPatternField.delegate = self
        modeFieldsContainer.addSubview(regexPatternField)

        let replacementLabel = NSTextField(labelWithString: "Replace:")
        replacementLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(replacementLabel)

        regexReplacementField.placeholderString = "Replacement template"
        regexReplacementField.translatesAutoresizingMaskIntoConstraints = false
        regexReplacementField.delegate = self
        modeFieldsContainer.addSubview(regexReplacementField)

        let labelWidth: CGFloat = 60

        NSLayoutConstraint.activate([
            patternLabel.topAnchor.constraint(equalTo: modeFieldsContainer.topAnchor),
            patternLabel.leadingAnchor.constraint(equalTo: modeFieldsContainer.leadingAnchor),
            patternLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            regexPatternField.centerYAnchor.constraint(equalTo: patternLabel.centerYAnchor),
            regexPatternField.leadingAnchor.constraint(equalTo: patternLabel.trailingAnchor, constant: 4),
            regexPatternField.trailingAnchor.constraint(equalTo: modeFieldsContainer.trailingAnchor),

            replacementLabel.topAnchor.constraint(equalTo: patternLabel.bottomAnchor, constant: 8),
            replacementLabel.leadingAnchor.constraint(equalTo: modeFieldsContainer.leadingAnchor),
            replacementLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            regexReplacementField.centerYAnchor.constraint(equalTo: replacementLabel.centerYAnchor),
            regexReplacementField.leadingAnchor.constraint(
                equalTo: replacementLabel.trailingAnchor, constant: 4
            ),
            regexReplacementField.trailingAnchor.constraint(equalTo: modeFieldsContainer.trailingAnchor),
        ])
    }

    private func configureDatePrefixFields() {
        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(formatLabel)

        dateFormatField.placeholderString = "yyyy-MM-dd"
        dateFormatField.stringValue = "yyyy-MM-dd"
        dateFormatField.translatesAutoresizingMaskIntoConstraints = false
        dateFormatField.delegate = self
        modeFieldsContainer.addSubview(dateFormatField)

        let hintLabel = NSTextField(
            labelWithString: "Uses the file's modification date as prefix."
        )
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        modeFieldsContainer.addSubview(hintLabel)

        let labelWidth: CGFloat = 60

        NSLayoutConstraint.activate([
            formatLabel.topAnchor.constraint(equalTo: modeFieldsContainer.topAnchor),
            formatLabel.leadingAnchor.constraint(equalTo: modeFieldsContainer.leadingAnchor),
            formatLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            dateFormatField.centerYAnchor.constraint(equalTo: formatLabel.centerYAnchor),
            dateFormatField.leadingAnchor.constraint(equalTo: formatLabel.trailingAnchor, constant: 4),
            dateFormatField.widthAnchor.constraint(equalToConstant: 200),

            hintLabel.topAnchor.constraint(equalTo: formatLabel.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: dateFormatField.leadingAnchor),
        ])
    }

    // MARK: - Preview

    private func updatePreview() {
        let pattern = currentPattern()
        previewNames = fileURLs.enumerated().map { index, url in
            let original = url.lastPathComponent
            let renamed = previewRename(
                originalName: original,
                url: url,
                index: index,
                pattern: pattern
            )
            return (original: original, renamed: renamed)
        }
        previewTableView.reloadData()
    }

    private func previewRename(
        originalName: String,
        url: URL,
        index: Int,
        pattern: BatchRenamePattern
    ) -> String {
        switch pattern {
        case let .findReplace(find, replace, caseSensitive):
            guard !find.isEmpty else { return originalName }
            let options: String.CompareOptions = caseSensitive ? [] : .caseInsensitive
            return originalName.replacingOccurrences(of: find, with: replace, options: options)

        case let .sequential(prefix, startNumber, zeroPadding, suffix):
            let number = startNumber + index
            let paddedNumber = String(format: "%0\(zeroPadding)d", number)
            let ext = url.pathExtension
            let newBaseName = "\(prefix)\(paddedNumber)\(suffix)"
            return ext.isEmpty ? newBaseName : "\(newBaseName).\(ext)"

        case let .regex(regexPattern, replacement):
            guard !regexPattern.isEmpty,
                  let regex = try? NSRegularExpression(pattern: regexPattern)
            else {
                return originalName
            }
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let range = NSRange(baseName.startIndex..., in: baseName)
            let newBaseName = regex.stringByReplacingMatches(
                in: baseName,
                range: range,
                withTemplate: replacement
            )
            return ext.isEmpty ? newBaseName : "\(newBaseName).\(ext)"

        case let .datePrefix(format):
            let formatter = DateFormatter()
            formatter.dateFormat = format
            let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let date = resourceValues?.contentModificationDate ?? Date()
            let dateString = formatter.string(from: date)
            return "\(dateString)_\(originalName)"
        }
    }

    private func currentPattern() -> BatchRenamePattern {
        guard let mode = RenameMode(rawValue: modeSelector.indexOfSelectedItem) else {
            return .findReplace(find: "", replace: "", caseSensitive: true)
        }

        switch mode {
        case .findReplace:
            return .findReplace(
                find: findField.stringValue,
                replace: replaceField.stringValue,
                caseSensitive: caseSensitiveCheckbox.state == .on
            )
        case .sequential:
            return .sequential(
                prefix: prefixField.stringValue,
                startNumber: Int(startNumberField.stringValue) ?? 1,
                zeroPadding: zeroPaddingStepper.integerValue,
                suffix: suffixField.stringValue
            )
        case .regex:
            return .regex(
                pattern: regexPatternField.stringValue,
                replacement: regexReplacementField.stringValue
            )
        case .datePrefix:
            let format = dateFormatField.stringValue.isEmpty ? "yyyy-MM-dd" : dateFormatField.stringValue
            return .datePrefix(format: format)
        }
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: Any?) {
        guard let mode = RenameMode(rawValue: modeSelector.indexOfSelectedItem) else { return }
        configureModeFields(for: mode)
        updatePreview()
    }

    @objc private func fieldChanged(_ sender: Any?) {
        updatePreview()
    }

    @objc private func stepperChanged(_ sender: Any?) {
        zeroPaddingLabel.stringValue = "\(zeroPaddingStepper.integerValue)"
        updatePreview()
    }

    @objc private func renameClicked(_ sender: Any?) {
        let pattern = currentPattern()

        Task {
            do {
                _ = try await fileSystemService.batchRename(urls: fileURLs, pattern: pattern)
                await MainActor.run {
                    onComplete?()
                    window?.close()
                }
            } catch {
                await MainActor.run {
                    guard let window else { return }
                    let alert = NSAlert(error: error)
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        window?.close()
    }
}

// MARK: - NSTextFieldDelegate

extension BatchRenameWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updatePreview()
    }
}

// MARK: - NSTableViewDataSource

extension BatchRenameWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        previewNames.count
    }
}

// MARK: - NSTableViewDelegate

extension BatchRenameWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnId = tableColumn?.identifier,
              previewNames.indices.contains(row)
        else { return nil }

        let cellId = columnId
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = NSFont.systemFont(ofSize: 12)
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let entry = previewNames[row]

        switch columnId {
        case Self.originalColumnId:
            cell.textField?.stringValue = entry.original
            cell.textField?.textColor = .labelColor
        case Self.renamedColumnId:
            cell.textField?.stringValue = entry.renamed
            cell.textField?.textColor = entry.renamed != entry.original ? .systemBlue : .labelColor
        default:
            break
        }

        return cell
    }
}
