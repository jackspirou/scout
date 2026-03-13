import AppKit

// MARK: - PreviewHeaderView

/// Reusable collapsible metadata header for preview panes.
/// Shows icon + filename + compact detail in collapsed state,
/// and an NSGridView with full metadata when expanded.
final class PreviewHeaderView: NSView {
    // MARK: - Properties

    private(set) var isExpanded = false

    private var iconView: NSImageView!
    private var nameLabel: NSTextField!
    private var compactDetailLabel: NSTextField!
    private var disclosureButton: NSButton!
    private var detailGrid: NSGridView!
    private var separator: NSBox!
    private(set) var heightConstraint: NSLayoutConstraint!

    private var sizeValueLabel: NSTextField!
    private var kindValueLabel: NSTextField!
    private var createdValueLabel: NSTextField!
    private var modifiedValueLabel: NSTextField!
    private var lastOpenedValueLabel: NSTextField!
    private var lockedValueLabel: NSTextField!
    private var permissionsValueLabel: NSTextField!
    private var whereValueLabel: NSTextField!
    private var copyPathButton: NSButton!

    private var modeControl: NSSegmentedControl!
    /// Called when the user toggles the Code/Preview segmented control.
    /// Parameter is the selected segment index (0 = Code, 1 = Preview).
    var onModeChanged: ((Int) -> Void)?

    private var compactDetailLeadingToName: NSLayoutConstraint!
    private var compactDetailTrailingToMode: NSLayoutConstraint!
    private var compactDetailTrailingToDisclosure: NSLayoutConstraint!

    private var currentItem: FileItem?

    // MARK: - Constants

    private enum Layout {
        static let collapsedHeight: CGFloat = 30
        static let expandedHeight: CGFloat = 112
        static let gridLabelWidth: CGFloat = 60
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configuration

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        configureSubviews()
        configureDetailGrid()
        configureSeparator()
        configureClickableRow()
        layoutViews()
    }

    private func configureSubviews() {
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel = NSTextField(labelWithString: "")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        compactDetailLabel = NSTextField(labelWithString: "")
        compactDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        compactDetailLabel.font = NSFont.systemFont(ofSize: 11)
        compactDetailLabel.textColor = .secondaryLabelColor
        compactDetailLabel.lineBreakMode = .byTruncatingTail
        compactDetailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        disclosureButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand")!,
            target: self, action: #selector(toggleExpansion)
        )
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.bezelStyle = .inline
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.symbolConfiguration = .init(pointSize: 10, weight: .medium)

        modeControl = NSSegmentedControl(labels: ["Code", "Preview"], trackingMode: .selectOne, target: self, action: #selector(modeControlChanged))
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.segmentStyle = .rounded
        modeControl.font = NSFont.systemFont(ofSize: 10)
        modeControl.controlSize = .mini
        modeControl.selectedSegment = 1
        modeControl.isHidden = true

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(modeControl)
        addSubview(compactDetailLabel)
        addSubview(disclosureButton)
    }

    private func configureDetailGrid() {
        let sizeLabel = makeGridLabel("Size")
        sizeValueLabel = makeGridValue()

        let kindLabel = makeGridLabel("Kind")
        kindValueLabel = makeGridValue()

        let createdLabel = makeGridLabel("Created")
        createdValueLabel = makeGridValue()

        let modifiedLabel = makeGridLabel("Modified")
        modifiedValueLabel = makeGridValue()

        let openedLabel = makeGridLabel("Opened")
        lastOpenedValueLabel = makeGridValue()

        let lockedLabel = makeGridLabel("Locked")
        lockedValueLabel = makeGridValue()

        let permsLabel = makeGridLabel("Perms")
        permissionsValueLabel = makeGridValue()

        let whereLabel = makeGridLabel("Where")
        whereValueLabel = makeGridValue()
        whereValueLabel.lineBreakMode = .byTruncatingTail

        copyPathButton = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy path")!,
            target: self, action: #selector(copyPathClicked)
        )
        copyPathButton.translatesAutoresizingMaskIntoConstraints = false
        copyPathButton.bezelStyle = .inline
        copyPathButton.isBordered = false
        copyPathButton.imagePosition = .imageOnly
        copyPathButton.symbolConfiguration = .init(pointSize: 10, weight: .regular)

        let whereValueStack = NSStackView(views: [copyPathButton, whereValueLabel])
        whereValueStack.orientation = .horizontal
        whereValueStack.spacing = 2
        copyPathButton.widthAnchor.constraint(equalToConstant: 16).isActive = true

        detailGrid = NSGridView(views: [
            [sizeLabel, sizeValueLabel, kindLabel, kindValueLabel],
            [createdLabel, createdValueLabel, openedLabel, lastOpenedValueLabel],
            [modifiedLabel, modifiedValueLabel, lockedLabel, lockedValueLabel],
            [permsLabel, permissionsValueLabel, whereLabel, whereValueStack],
        ])
        detailGrid.translatesAutoresizingMaskIntoConstraints = false

        for col in [0, 2] {
            detailGrid.column(at: col).xPlacement = .fill
            detailGrid.column(at: col).width = Layout.gridLabelWidth
        }
        for col in [1, 3] {
            detailGrid.column(at: col).xPlacement = .fill
        }

        detailGrid.rowSpacing = 4
        detailGrid.columnSpacing = 4
        detailGrid.isHidden = true

        addSubview(detailGrid)
    }

    private func configureSeparator() {
        separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = .separatorColor

        // Add separator as a sibling — it sits visually below the header but is
        // owned by the header so parent VCs don't need to manage it separately.
        addSubview(separator)
    }

    private func configureClickableRow() {
        let clickable = ClickableView(target: self, action: #selector(toggleExpansion))
        clickable.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clickable)

        // Clickable area stops before the mode control so it doesn't steal clicks
        NSLayoutConstraint.activate([
            clickable.topAnchor.constraint(equalTo: topAnchor),
            clickable.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickable.trailingAnchor.constraint(equalTo: modeControl.leadingAnchor, constant: -4),
            clickable.heightAnchor.constraint(equalToConstant: Layout.collapsedHeight),
        ])
    }

    private func layoutViews() {
        heightConstraint = heightAnchor.constraint(equalToConstant: Layout.collapsedHeight)

        compactDetailLeadingToName = compactDetailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8)
        compactDetailLeadingToName.isActive = true

        // Compact detail trailing — to mode control when visible, otherwise to disclosure
        compactDetailTrailingToMode = compactDetailLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeControl.leadingAnchor, constant: -6)
        compactDetailTrailingToDisclosure = compactDetailLabel.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -4)
        compactDetailTrailingToDisclosure.isActive = true

        NSLayoutConstraint.activate([
            heightConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            compactDetailLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            // Mode control sits to the right, before the disclosure button
            modeControl.trailingAnchor.constraint(equalTo: disclosureButton.leadingAnchor, constant: -6),
            modeControl.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            disclosureButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            disclosureButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 16),
            disclosureButton.heightAnchor.constraint(equalToConstant: 16),

            detailGrid.topAnchor.constraint(equalTo: topAnchor, constant: Layout.collapsedHeight + 2),
            detailGrid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            detailGrid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            // Separator pinned to the bottom edge of the header.
            separator.topAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: - Public API

    /// Total height including the 1px separator.
    static var collapsedHeight: CGFloat { Layout.collapsedHeight }

    /// Updates all header fields from the given FileItem.
    func update(with item: FileItem) {
        currentItem = item
        iconView.image = item.icon
        nameLabel.stringValue = item.name
        compactDetailLabel.stringValue = [item.formattedSize, item.kind].joined(separator: " \u{00B7} ")

        sizeValueLabel.stringValue = item.formattedSize
        kindValueLabel.stringValue = item.kind
        createdValueLabel.stringValue = item.creationDate?.fullFormatted ?? "--"
        modifiedValueLabel.stringValue = item.modificationDate?.fullFormatted ?? "--"
        lastOpenedValueLabel.stringValue = item.lastOpenedDate?.fullFormatted ?? "--"
        lockedValueLabel.stringValue = item.isLocked ? "Yes" : "No"
        permissionsValueLabel.stringValue = item.formattedPermissions
        whereValueLabel.stringValue = item.url.path
    }

    /// Updates the compact detail label with a custom string (e.g. image dimensions).
    func setCompactDetail(_ text: String) {
        compactDetailLabel.stringValue = text
    }

    /// Shows or hides the Code/Preview segmented control for markdown files.
    func setMarkdownMode(_ show: Bool) {
        modeControl.isHidden = !show
        if show {
            modeControl.selectedSegment = 1
            compactDetailTrailingToDisclosure.isActive = false
            compactDetailTrailingToMode.isActive = true
        } else {
            compactDetailTrailingToMode.isActive = false
            compactDetailTrailingToDisclosure.isActive = true
        }
    }

    /// Updates the background layer for appearance changes.
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
                heightConstraint.constant = Layout.expandedHeight
                detailGrid.isHidden = false
                compactDetailLabel.isHidden = true
                disclosureButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Collapse")
            } else {
                heightConstraint.constant = Layout.collapsedHeight
                detailGrid.isHidden = true
                compactDetailLabel.isHidden = false
                disclosureButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand")
            }

        } completionHandler: { [weak self] in
            self?.superview?.layoutSubtreeIfNeeded()
        }
    }

    @objc private func modeControlChanged() {
        onModeChanged?(modeControl.selectedSegment)
    }

    @objc private func copyPathClicked() {
        guard let item = currentItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)

        copyPathButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyPathButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy path")
        }
    }

    // MARK: - Private Helpers

    private func makeGridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        return label
    }

    private func makeGridValue() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}

// MARK: - ClickableView

/// Transparent view that forwards mouse clicks to a target/action pair.
private final class ClickableView: NSView {
    private weak var target: AnyObject?
    private let action: Selector

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        _ = target?.perform(action)
    }
}
