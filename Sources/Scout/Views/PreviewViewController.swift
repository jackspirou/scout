import AppKit

// MARK: - PreviewChild Protocol

/// Protocol for preview child view controllers that can display a file item and clear their state.
protocol PreviewChild: NSViewController {
    func displayItem(_ item: FileItem)
    func clear()
}

// MARK: - PreviewViewController

/// Container view controller for the preview pane. Swaps between content-specific
/// child view controllers based on file type. Each child owns its own header.
/// Supports text, image, and directory previews.
final class PreviewViewController: NSViewController {
    // MARK: - Properties

    private var contentContainer: NSView!
    private let placeholderLabel = NSTextField(labelWithString: "Select a file to preview")

    private let textPreview = TextFilePreviewViewController()
    private let imagePreview = ImagePreviewViewController()
    private let pdfPreview = PDFPreviewViewController()
    private let videoPreview = VideoPreviewViewController()
    private let audioPreview = AudioPreviewViewController()
    private let documentPreview = DocumentPreviewViewController()
    private let archivePreview = ArchivePreviewViewController()
    private let directoryPreview = DirectoryPreviewViewController()
    private weak var activeChild: NSViewController?

    /// Called when the user double-clicks a directory in the directory preview.
    var onNavigate: ((URL) -> Void)? {
        didSet { directoryPreview.onNavigate = onNavigate }
    }

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
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

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

        if item.isDirectory {
            showChild(directoryPreview)
            directoryPreview.displayItem(item)
        } else if item.isPDF {
            showChild(pdfPreview)
            pdfPreview.displayItem(item)
        } else if item.isVideo {
            showChild(videoPreview)
            videoPreview.displayItem(item)
        } else if item.isAudio {
            showChild(audioPreview)
            audioPreview.displayItem(item)
        } else if item.isImage {
            showChild(imagePreview)
            imagePreview.displayItem(item)
        } else if item.isRichDocument {
            showChild(documentPreview)
            documentPreview.displayItem(item)
        } else if item.isArchive {
            showChild(archivePreview)
            archivePreview.displayItem(item)
        } else if item.isText {
            showChild(textPreview)
            textPreview.displayItem(item)
        } else {
            removeActiveChild()
            contentContainer.isHidden = true
            placeholderLabel.stringValue = "No preview available"
            placeholderLabel.isHidden = false
        }
    }

    /// Returns `true` if the active preview handles spacebar for play/pause.
    var handlesSpacebar: Bool {
        activeChild is AudioPreviewViewController
    }

    /// Forwards a spacebar press to the active audio preview.
    func togglePlayback() {
        (activeChild as? AudioPreviewViewController)?.togglePlayPause()
    }

    /// Clears the preview and shows the default placeholder.
    func clearPreview() {
        removeActiveChild()
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
        (child as? PreviewChild)?.clear()
        child.view.removeFromSuperview()
        child.removeFromParent()
        activeChild = nil
    }
}
