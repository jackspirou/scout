import Cocoa

// MARK: - SearchTokenBarView

/// A horizontal bar of removable filter token pills shown during search.
final class SearchTokenBarView: NSView {
    var onRemoveToken: ((Int) -> Void)?

    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true

        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(tokens: [SearchFilterToken.DisplayToken]) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, token) in tokens.enumerated() {
            let pill = SearchTokenPillView(token: token, index: index)
            pill.onRemove = { [weak self] idx in
                self?.onRemoveToken?(idx)
            }
            stackView.addArrangedSubview(pill)
        }

        isHidden = tokens.isEmpty
    }
}

// MARK: - SearchTokenPillView

private final class SearchTokenPillView: NSView {
    var onRemove: ((Int) -> Void)?

    private let index: Int

    init(token: SearchFilterToken.DisplayToken, index: Int) {
        self.index = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup(token: token)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(token: SearchFilterToken.DisplayToken) {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = pillColor(for: token.category).withAlphaComponent(0.15).cgColor

        let label = NSTextField(labelWithString: token.label)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = pillColor(for: token.category)
        label.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "\u{2715}", target: self, action: #selector(removeClicked))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        closeButton.contentTintColor = pillColor(for: token.category)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 6)

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func pillColor(for category: SearchFilterToken.Category) -> NSColor {
        switch category {
        case .kind: return .systemBlue
        case .size: return .systemGreen
        case .modified: return .systemOrange
        case .tag: return .systemPurple
        }
    }

    @objc private func removeClicked() {
        onRemove?(index)
    }
}
