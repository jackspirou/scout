import AppKit

// MARK: - PreviewViewController

/// Container view controller for the preview pane. Swaps between content-specific
/// child view controllers based on file type. Each child owns its own header.
/// Currently supports text file preview; extensible for directories, images, etc.
final class PreviewViewController: NSViewController {
    // MARK: - Properties

    private var contentContainer: NSView!
    private let placeholderLabel = NSTextField(labelWithString: "Select a file to preview")

    private let textPreview = TextFilePreviewViewController()
    private weak var activeChild: NSViewController?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configureContentContainer()
        configurePlaceholder()
        layoutSubviews()
    }

    // MARK: - Configuration

    private func configureContentContainer() {
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        view.addSubview(contentContainer)
    }

    private func configurePlaceholder() {
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = NSFont.systemFont(ofSize: 14)
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.isHidden = false
        view.addSubview(placeholderLabel)
    }

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            // Content container fills entire view.
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Placeholder centered in view.
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Public API

    /// Previews the given file item, selecting the appropriate child view controller.
    func previewItem(_ item: FileItem?) {
        guard let item = item else {
            clearPreview()
            return
        }

        guard item.isText else {
            removeActiveChild()
            contentContainer.isHidden = true
            placeholderLabel.stringValue = "No preview available"
            placeholderLabel.isHidden = false
            return
        }

        showChild(textPreview)
        textPreview.displayItem(item)
    }

    /// Clears the preview and shows the default placeholder.
    func clearPreview() {
        removeActiveChild()
        textPreview.clear()
        contentContainer.isHidden = true
        placeholderLabel.stringValue = "Select a file to preview"
        placeholderLabel.isHidden = false
    }

    // MARK: - Private Helpers

    private func showChild(_ child: NSViewController) {
        placeholderLabel.isHidden = true
        contentContainer.isHidden = false

        guard activeChild !== child else { return }

        removeActiveChild()
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(child.view)

        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])

        activeChild = child
    }

    private func removeActiveChild() {
        guard let child = activeChild else { return }
        child.view.removeFromSuperview()
        child.removeFromParent()
        activeChild = nil
    }
}
