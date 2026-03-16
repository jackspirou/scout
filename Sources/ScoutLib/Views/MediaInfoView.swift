import AppKit

/// A row of metadata to display in a MediaInfoView.
struct MediaInfoRow {
    let label: String
    let value: String
}

/// Generic collapsible metadata section for media-specific info.
/// Displays a title, compact summary, and expandable key-value grid.
/// Used by ImagePreviewViewController (and future video preview) to show
/// media metadata below the file header.
final class MediaInfoView: NSView {
    // Properties
    private(set) var isExpanded = false
    private var titleLabel: NSTextField!
    private var summaryLabel: NSTextField!
    private var disclosureButton: NSButton!
    private var rowStack: NSStackView! // vertical stack of row views
    private var separator: NSBox!
    private(set) var heightConstraint: NSLayoutConstraint!

    private var rows: [MediaInfoRow] = []

    private enum Layout {
        static let collapsedHeight: CGFloat = 26
        static let rowHeight: CGFloat = 18
        static let labelWidth: CGFloat = 80
    }

    /// Init
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Configuration - build all subviews
    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Title label (left-aligned, bold-ish)
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        // Summary label (middle, truncating)
        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = NSFont.systemFont(ofSize: 11)
        summaryLabel.textColor = .tertiaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Disclosure chevron
        disclosureButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand")!,
            target: self, action: #selector(toggleExpansion)
        )
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.bezelStyle = .inline
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.symbolConfiguration = .init(pointSize: 9, weight: .medium)

        // Row stack (vertical, hidden when collapsed)
        rowStack = NSStackView()
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        rowStack.isHidden = true

        // Separator
        separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = .separatorColor

        // Clickable area for the title row
        let clickable = ClickableAreaView(target: self, action: #selector(toggleExpansion))
        clickable.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(rowStack)
        addSubview(separator)
        addSubview(clickable)
        addSubview(disclosureButton)

        heightConstraint = heightAnchor.constraint(equalToConstant: Layout.collapsedHeight)

        NSLayoutConstraint.activate([
            heightConstraint,

            clickable.topAnchor.constraint(equalTo: topAnchor),
            clickable.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickable.trailingAnchor.constraint(equalTo: disclosureButton.leadingAnchor),
            clickable.heightAnchor.constraint(equalToConstant: Layout.collapsedHeight),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Layout.collapsedHeight / 2),

            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -4
            ),
            summaryLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            disclosureButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            disclosureButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 14),
            disclosureButton.heightAnchor.constraint(equalToConstant: 14),

            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: Layout.collapsedHeight),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: - Public API

    /// Updates the view with new metadata rows.
    /// Pass an empty array to hide the view.
    func update(title: String, compactSummary: String, rows: [MediaInfoRow]) {
        self.rows = rows
        titleLabel.stringValue = title
        summaryLabel.stringValue = compactSummary

        // Rebuild row views
        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            let rowView = makeRowView(label: row.label, value: row.value)
            rowStack.addArrangedSubview(rowView)
        }

        // Hide entirely if no rows
        isHidden = rows.isEmpty

        // Update expanded height based on row count
        if isExpanded {
            heightConstraint.constant = expandedHeight()
        }
    }

    func updateAppearance() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    // MARK: - Actions

    @objc private func toggleExpansion() {
        isExpanded.toggle()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true

            if isExpanded {
                heightConstraint.constant = expandedHeight()
                rowStack.isHidden = false
                summaryLabel.isHidden = true
                disclosureButton.image = NSImage(
                    systemSymbolName: "chevron.up", accessibilityDescription: "Collapse"
                )
            } else {
                heightConstraint.constant = Layout.collapsedHeight
                rowStack.isHidden = true
                summaryLabel.isHidden = false
                disclosureButton.image = NSImage(
                    systemSymbolName: "chevron.down", accessibilityDescription: "Expand"
                )
            }

        } completionHandler: { [weak self] in
            self?.superview?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Private

    private func expandedHeight() -> CGFloat {
        Layout.collapsedHeight + CGFloat(rows.count) * Layout.rowHeight + 6
    }

    private func makeRowView(label: String, value: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = NSFont.systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right

        let valueField = NSTextField(labelWithString: value)
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.font = NSFont.systemFont(ofSize: 11)
        valueField.textColor = .labelColor
        valueField.lineBreakMode = .byTruncatingTail
        valueField.isSelectable = true // Allow copying metadata values
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addSubview(labelField)
        container.addSubview(valueField)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: Layout.rowHeight),
            labelField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labelField.widthAnchor.constraint(equalToConstant: Layout.labelWidth),
            labelField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            valueField.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 8),
            valueField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            valueField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }
}

// MARK: - ClickableAreaView

/// Transparent view that forwards clicks to a target/action.
private final class ClickableAreaView: NSView {
    private weak var target: AnyObject?
    private let action: Selector

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func mouseDown(with event: NSEvent) {
        _ = target?.perform(action)
    }
}
