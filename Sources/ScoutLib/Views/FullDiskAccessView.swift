import AppKit

// MARK: - FullDiskAccessView

/// A zero-state onboarding view shown when the app lacks Full Disk Access.
/// Displays a centered layout with an icon, explanation, and a button to
/// open System Settings.
final class FullDiskAccessView: NSView {
    // MARK: - Subviews

    private let iconImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if let image = NSImage(
            systemSymbolName: "lock.shield",
            accessibilityDescription: "Full Disk Access"
        ) {
            let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
            imageView.image = image.withSymbolConfiguration(config)
        }
        imageView.contentTintColor = .secondaryLabelColor
        return imageView
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Full Disk Access Required")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .boldSystemFont(ofSize: 17)
        label.textColor = .labelColor
        label.alignment = .center
        return label
    }()

    private let descriptionLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString:
            "Scout is a file manager that needs access to browse all your files and folders. "
                + "Without Full Disk Access, many directories will be inaccessible.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 400
        return label
    }()

    private let openSettingsButton: NSButton = {
        let button = NSButton(title: "Open System Settings", target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        return button
    }()

    private let hintLabel: NSTextField = {
        let label = NSTextField(labelWithString: "After granting access, Scout will continue automatically.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        return label
    }()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupView() {
        wantsLayer = true

        // Stack all elements vertically
        let stackView = NSStackView(views: [
            iconImageView,
            titleLabel,
            descriptionLabel,
            openSettingsButton,
            hintLabel,
        ])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12

        // Add extra spacing after icon and after description
        stackView.setCustomSpacing(16, after: iconImageView)
        stackView.setCustomSpacing(20, after: descriptionLabel)
        stackView.setCustomSpacing(16, after: openSettingsButton)

        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])

        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsClicked)
    }

    // MARK: - Appearance

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackgroundColor()
    }

    override func updateLayer() {
        updateBackgroundColor()
    }

    private func updateBackgroundColor() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    // MARK: - Actions

    @objc private func openSettingsClicked(_ sender: Any?) {
        FullDiskAccessService.shared.openSystemSettings()
    }
}
