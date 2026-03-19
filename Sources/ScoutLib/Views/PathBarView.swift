import Cocoa

// MARK: - PathBarDelegate

protocol PathBarDelegate: AnyObject {
    /// Called when the user clicks a path component to navigate.
    func pathBar(_ pathBar: PathBarView, didNavigateTo url: URL)
    /// Called when the user directly edits the path text and presses Enter.
    func pathBar(_ pathBar: PathBarView, didEditPath url: URL)
}

// MARK: - PathBarView

final class PathBarView: NSView {
    // MARK: - Properties

    weak var delegate: PathBarDelegate?

    private let scrollView = NSScrollView()
    private let componentStack = NSStackView()
    private let editField = NSTextField()

    private var currentURL: URL?
    private var isEditing: Bool = false
    private var iconStyle: IconStyle = .system

    // MARK: - Constants

    private enum Layout {
        static let componentSpacing: CGFloat = 2
        static let horizontalPadding: CGFloat = 8
        static let iconSize: CGFloat = 14
        static let separatorFontSize: CGFloat = 10
        static let componentFontSize: CGFloat = 12
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        configureComponentStack()
        configureScrollView()
        configureEditField()
        layoutViews()
        registerForCommandL()
    }

    // MARK: - Configuration

    private func configureComponentStack() {
        componentStack.orientation = .horizontal
        componentStack.spacing = Layout.componentSpacing
        componentStack.distribution = .gravityAreas
        componentStack.alignment = .centerY
        componentStack.translatesAutoresizingMaskIntoConstraints = false
        componentStack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Layout.horizontalPadding,
            bottom: 0,
            right: Layout.horizontalPadding
        )
    }

    private func configureScrollView() {
        scrollView.documentView = componentStack
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
    }

    private func configureEditField() {
        editField.font = NSFont.systemFont(ofSize: Layout.componentFontSize)
        editField.isEditable = true
        editField.isBordered = true
        editField.bezelStyle = .roundedBezel
        editField.isHidden = true
        editField.translatesAutoresizingMaskIntoConstraints = false
        editField.delegate = self
        editField.focusRingType = .exterior
        editField.cell?.sendsActionOnEndEditing = true
        editField.target = self
        editField.action = #selector(editFieldAction(_:))
        addSubview(editField)
    }

    private func layoutViews() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            componentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            componentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            componentStack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),

            editField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            editField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            editField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            editField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    private func registerForCommandL() {
        // The Cmd+L shortcut is handled via keyDown override
    }

    // MARK: - Public API

    /// Updates the path bar to display the given URL's components.
    func update(with url: URL) {
        currentURL = url
        rebuildComponents()
    }

    /// Updates the icon style and rebuilds components to apply the new style.
    func setIconStyle(_ style: IconStyle) {
        iconStyle = style
        rebuildComponents()
    }

    // MARK: - Component Rendering

    private func rebuildComponents() {
        componentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let url = currentURL else { return }

        let pathComponents = url.pathComponents
        var accumulatedURL = URL(fileURLWithPath: "/")

        for (index, component) in pathComponents.enumerated() {
            // Build accumulated URL
            if index == 0 {
                accumulatedURL = URL(fileURLWithPath: "/")
            } else {
                accumulatedURL = accumulatedURL.appendingPathComponent(component)
            }

            // Add separator arrow before each component except the first
            if index > 0 {
                let separator = makeSeparator()
                componentStack.addArrangedSubview(separator)
            }

            let componentView = makeComponentButton(
                name: index == 0 ? "/" : component,
                url: accumulatedURL,
                isLast: index == pathComponents.count - 1
            )
            componentStack.addArrangedSubview(componentView)
        }

        // Scroll to the right (latest component)
        DispatchQueue.main.async { [weak self] in
            guard let self, let documentView = self.scrollView.documentView else { return }
            let maxScrollX = max(0, documentView.frame.width - self.scrollView.contentSize.width)
            self.scrollView.contentView.scroll(to: NSPoint(x: maxScrollX, y: 0))
        }
    }

    private func makeComponentButton(name: String, url: URL, isLast: Bool) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 3
        container.alignment = .centerY

        // Only show icon for the current (last) directory
        if isLast {
            let icon = NSImageView()
            let resolved = FileTypeResolver.resolve(url: url, isDirectory: true, systemKind: nil, iconStyle: iconStyle)
            icon.image = resolved.icon
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: Layout.iconSize).isActive = true
            icon.heightAnchor.constraint(equalToConstant: Layout.iconSize).isActive = true
            container.addArrangedSubview(icon)
        }

        // Name button
        let button = PathComponentButton(title: name, url: url)
        button.target = self
        button.action = #selector(componentClicked(_:))
        button.isBordered = false
        button.font = NSFont.systemFont(
            ofSize: Layout.componentFontSize,
            weight: isLast ? .semibold : .regular
        )
        button.contentTintColor = isLast ? .labelColor : .secondaryLabelColor

        container.addArrangedSubview(button)

        return container
    }

    private func makeSeparator() -> NSTextField {
        let separator = NSTextField(labelWithString: "\u{203A}") // right single angle quotation mark
        separator.font = NSFont.systemFont(ofSize: Layout.separatorFontSize, weight: .medium)
        separator.textColor = .tertiaryLabelColor
        separator.alignment = .center
        return separator
    }

    // MARK: - Actions

    @objc private func componentClicked(_ sender: PathComponentButton) {
        delegate?.pathBar(self, didNavigateTo: sender.url)
    }

    @objc private func editFieldAction(_ sender: NSTextField) {
        commitEditField()
    }

    // MARK: - Edit Mode (Cmd+L)

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == .command, event.charactersIgnoringModifiers == "l" {
            enterEditMode()
            return
        }

        if isEditing, event.keyCode == 53 /* Escape */ {
            cancelEditMode()
            return
        }

        super.keyDown(with: event)
    }

    /// Shows the text field for direct path editing.
    func enterEditMode() {
        isEditing = true
        editField.stringValue = currentURL?.path ?? "/"
        editField.isHidden = false
        scrollView.isHidden = true
        window?.makeFirstResponder(editField)
        editField.selectText(nil)
    }

    /// Commits the text field value and navigates.
    private func commitEditField() {
        let path = editField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !path.isEmpty else {
            cancelEditMode()
            return
        }

        // Expand tilde
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            exitEditMode()
            delegate?.pathBar(self, didEditPath: url)
        } else {
            // Shake the field to indicate invalid path
            shakeEditField()
        }
    }

    /// Cancels editing without navigating.
    private func cancelEditMode() {
        exitEditMode()
    }

    private func exitEditMode() {
        isEditing = false
        editField.isHidden = true
        scrollView.isHidden = false
        window?.makeFirstResponder(superview)
    }

    private func shakeEditField() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [-8, 8, -6, 6, -4, 4, -2, 2, 0]
        editField.layer?.add(animation, forKey: "shake")
    }
}

// MARK: - NSTextFieldDelegate

extension PathBarView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditMode()
            return true
        }
        return false
    }
}

// MARK: - PathComponentButton

/// A button that stores its associated URL for path component navigation.
private final class PathComponentButton: NSButton {
    let url: URL

    init(title: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
