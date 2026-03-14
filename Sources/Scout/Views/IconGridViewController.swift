import Cocoa
import Quartz
import UniformTypeIdentifiers

// MARK: - IconGridViewDelegate

/// Delegate protocol for IconGridViewController, mirroring FileListViewDelegate callbacks.
protocol IconGridViewDelegate: AnyObject {
    func iconGridView(_ controller: IconGridViewController, didSelectItems items: [FileItem])
    func iconGridView(_ controller: IconGridViewController, didOpenItem item: FileItem)
    func iconGridView(_ controller: IconGridViewController, didRequestContextMenu items: [FileItem])
    func iconGridViewDidFinishLoading(_ controller: IconGridViewController, itemCount: Int)
}

// MARK: - IconGridCollectionViewItem

/// Custom NSCollectionViewItem that displays a file icon with a name label below.
final class IconGridCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconGridCollectionViewItem")

    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    private var iconSizeConstraintWidth: NSLayoutConstraint?
    private var iconSizeConstraintHeight: NSLayoutConstraint?

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.imageAlignment = .alignCenter
        container.addSubview(iconImageView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 2
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.textColor = .labelColor
        nameLabel.isEditable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        container.addSubview(nameLabel)

        let widthConstraint = iconImageView.widthAnchor.constraint(equalToConstant: 64)
        let heightConstraint = iconImageView.heightAnchor.constraint(equalToConstant: 64)
        iconSizeConstraintWidth = widthConstraint
        iconSizeConstraintHeight = heightConstraint

        NSLayoutConstraint.activate([
            iconImageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            iconImageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            widthConstraint,
            heightConstraint,

            nameLabel.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4),
        ])

        view = container
    }

    func configure(with item: FileItem, iconSize: CGFloat) {
        iconImageView.image = item.icon
        nameLabel.stringValue = item.name
        iconSizeConstraintWidth?.constant = iconSize
        iconSizeConstraintHeight?.constant = iconSize
    }

    override var isSelected: Bool {
        didSet {
            view.wantsLayer = true
            if isSelected {
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                view.layer?.cornerRadius = 6
            } else {
                view.layer?.backgroundColor = nil
            }
        }
    }
}

// MARK: - IconGridViewController

final class IconGridViewController: NSViewController {
    // MARK: - Properties

    weak var delegate: IconGridViewDelegate?

    private let fileSystemService = FileSystemService.shared
    private let clipboardManager = ClipboardManager()
    private var sortedItems: [FileItem] = []
    private(set) var currentDirectoryURL: URL?
    private var iconSize: CGFloat = 64
    private var showHiddenFiles: Bool = false
    private var loadingTask: Task<Void, Never>?

    /// Routes Cmd+Z through the centralized FileUndoManager.
    override var undoManager: UndoManager? {
        FileUndoManager.shared.undoManager
    }

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()

    /// The number of items currently displayed.
    var itemCount: Int {
        sortedItems.count
    }

    /// The items currently displayed.
    var currentItems: [FileItem] {
        sortedItems
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        configureCollectionView()
        configureScrollView()
        layoutScrollView()
    }

    // MARK: - Configuration

    private func configureCollectionView() {
        updateFlowLayoutItemSize()
        flowLayout.minimumInteritemSpacing = 10
        flowLayout.minimumLineSpacing = 10
        flowLayout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = self
        collectionView.dataSource = self

        collectionView.register(
            IconGridCollectionViewItem.self,
            forItemWithIdentifier: IconGridCollectionViewItem.identifier
        )

        // Register for drag and drop
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    private func configureScrollView() {
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = true
        view.addSubview(scrollView)
    }

    private func layoutScrollView() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func updateFlowLayoutItemSize() {
        let labelHeight: CGFloat = 40
        flowLayout.itemSize = NSSize(width: iconSize + 20, height: iconSize + labelHeight)
    }

    // MARK: - Public API

    /// Loads directory contents asynchronously.
    func loadDirectory(
        at url: URL,
        sortedBy sortField: SortField = .name,
        order: SortOrder = .ascending
    ) {
        let showHiddenFiles = self.showHiddenFiles
        loadingTask?.cancel()
        currentDirectoryURL = url

        loadingTask = Task { [weak self] in
            guard let self else { return }

            let items = (try? await self.fileSystemService.contentsOfDirectory(
                at: url, sortedBy: sortField, order: order, showHiddenFiles: showHiddenFiles
            )) ?? []

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.sortedItems = items
                self.collectionView.reloadData()
                self.delegate?.iconGridViewDidFinishLoading(self, itemCount: self.sortedItems.count)
            }
        }
    }

    /// Returns the currently selected items.
    func selectedItems() -> [FileItem] {
        collectionView.selectionIndexPaths.compactMap { indexPath in
            let index = indexPath.item
            return sortedItems.indices.contains(index) ? sortedItems[index] : nil
        }
    }

    /// Updates the icon size and refreshes the layout.
    func setIconSize(_ size: CGFloat) {
        iconSize = max(32, min(128, size))
        updateFlowLayoutItemSize()
        collectionView.reloadData()
    }

    /// Updates the show hidden files setting and reloads.
    func setShowHiddenFiles(_ show: Bool) {
        showHiddenFiles = show
        if let url = currentDirectoryURL {
            loadDirectory(at: url)
        }
    }

    /// Updates the icon style and reloads.
    func setIconStyle(_ style: IconStyle) {
        Task { await fileSystemService.setIconStyle(style) }
        if let url = currentDirectoryURL {
            loadDirectory(at: url)
        }
    }

    // MARK: - Menu Validation

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == NSSelectorFromString("contextRename:") {
            return false
        }
        return true
    }

    // MARK: - Context Menu Actions

    @objc func contextOpen(_ sender: NSMenuItem) {
        let items = selectedItems()
        for item in items {
            if item.isDirectory {
                delegate?.iconGridView(self, didOpenItem: item)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    @objc func contextOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let urls = selectedItems().map(\.url)
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @objc func contextGetInfo(_ sender: NSMenuItem) {
        let urls = selectedItems().map(\.url)
        guard !urls.isEmpty else { return }
        FinderHelper.showGetInfo(for: urls)
    }

    @objc func contextRename(_ sender: NSMenuItem) {
        // Renaming is not supported in icon grid view (no inline editing).
    }

    @objc func contextCopy(_ sender: NSMenuItem) {
        let urls = selectedItems().map(\.url)
        guard !urls.isEmpty else { return }
        clipboardManager.copy(urls: urls)
    }

    @objc func contextCopyPath(_ sender: NSMenuItem) {
        let paths = selectedItems().map(\.url.path)
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func contextCut(_ sender: NSMenuItem) {
        let urls = selectedItems().map(\.url)
        guard !urls.isEmpty else { return }
        clipboardManager.cut(urls: urls)
    }

    @objc func contextPaste(_ sender: NSMenuItem) {
        guard let destinationURL = currentDirectoryURL else { return }
        guard clipboardManager.canPaste() else { return }

        Task {
            do {
                try await clipboardManager.paste(to: destinationURL)
                loadDirectory(at: destinationURL)
            } catch {
                showError(error)
            }
        }
    }

    @objc func contextDuplicate(_ sender: NSMenuItem) {
        let items = selectedItems()
        guard !items.isEmpty else { return }

        let urls = items.map(\.url)
        let dir = currentDirectoryURL
        Task {
            let result: (error: (any Error)?, duplicatedURLs: [URL]) = await Task.detached {
                let fm = FileManager.default
                var error: (any Error)?
                var duplicatedURLs: [URL] = []
                for url in urls {
                    let parentDir = url.deletingLastPathComponent()
                    let baseName = url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension
                    let copyName = ext.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(ext)"
                    let destURL = parentDir.appendingPathComponent(copyName)
                    do {
                        try fm.copyItem(at: url, to: destURL)
                        duplicatedURLs.append(destURL)
                    } catch let e {
                        if error == nil { error = e }
                    }
                }
                return (error, duplicatedURLs)
            }.value
            for dupURL in result.duplicatedURLs {
                FileUndoManager.shared.recordDuplicate(duplicateURL: dupURL)
            }
            if let firstError = result.error {
                showError(firstError)
            }
            if let dir {
                loadDirectory(at: dir)
            }
        }
    }

    @objc func makeAlias(_ sender: Any?) {
        let items = selectedItems()
        guard !items.isEmpty, let dir = currentDirectoryURL else { return }

        Task.detached { [fileSystemService] in
            var created: [URL] = []
            var error: (any Error)?
            for item in items {
                do {
                    let aliasURL = try fileSystemService.createAlias(
                        for: item.url,
                        at: dir
                    )
                    created.append(aliasURL)
                } catch let e {
                    if error == nil { error = e }
                }
            }
            let capturedURLs = created
            let capturedError = error
            await MainActor.run { [weak self] in
                for aliasURL in capturedURLs {
                    FileUndoManager.shared.recordAlias(url: aliasURL)
                }
                if let capturedError {
                    self?.showError(capturedError)
                }
                if let dir = self?.currentDirectoryURL {
                    self?.loadDirectory(at: dir)
                }
            }
        }
    }

    @objc func contextMoveToTrash(_ sender: NSMenuItem) {
        let items = selectedItems()
        guard !items.isEmpty else { return }
        let originalURLs = items.map(\.url)
        Task {
            do {
                let trashedURLs = try await fileSystemService.trashItems(urls: originalURLs)
                FileUndoManager.shared.recordTrash(originalURLs: originalURLs, trashedURLs: trashedURLs)
                if let dir = currentDirectoryURL {
                    loadDirectory(at: dir)
                }
            } catch {
                showError(error)
            }
        }
    }

    @objc func contextQuickLook(_ sender: NSMenuItem) {
        toggleQuickLook()
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc func contextShowInFinder(_ sender: NSMenuItem) {
        let urls = selectedItems().map(\.url)
        if urls.isEmpty {
            if let dir = currentDirectoryURL {
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    @objc func contextCompress(_ sender: NSMenuItem) {
        let urls = selectedItems().map(\.url)
        guard !urls.isEmpty, let parentDir = currentDirectoryURL else { return }

        let archiveName = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent + ".zip"
            : "Archive.zip"
        let archivePath = parentDir.appendingPathComponent(archiveName).path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", archivePath] + urls.map(\.lastPathComponent)
        process.currentDirectoryURL = parentDir
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.loadDirectory(at: parentDir)
            }
        }
        do {
            try process.run()
        } catch {
            showError(error)
        }
    }

    @objc func contextNewFolder(_ sender: NSMenuItem) {
        guard let dir = currentDirectoryURL else { return }
        Task {
            do {
                let folderURL = try await fileSystemService.createDirectory(at: dir, named: "untitled folder")
                FileUndoManager.shared.recordNewFolder(url: folderURL)
                loadDirectory(at: dir)
            } catch {
                showError(error)
            }
        }
    }

    // MARK: - Helpers

    private func showError(_ error: Error) {
        guard let window = view.window else {
            NSLog("Scout: %@", error.localizedDescription)
            return
        }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }
}

// MARK: - NSCollectionViewDataSource

extension IconGridViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sortedItems.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: IconGridCollectionViewItem.identifier,
            for: indexPath
        )
        if let gridItem = item as? IconGridCollectionViewItem, sortedItems.indices.contains(indexPath.item) {
            gridItem.configure(with: sortedItems[indexPath.item], iconSize: iconSize)
        }
        return item
    }

    // MARK: - Drag Source

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        guard sortedItems.indices.contains(indexPath.item) else { return nil }
        return sortedItems[indexPath.item].url as NSURL
    }
}

// MARK: - NSCollectionViewDelegate

extension IconGridViewController: NSCollectionViewDelegate {
    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        delegate?.iconGridView(self, didSelectItems: selectedItems())
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        delegate?.iconGridView(self, didSelectItems: selectedItems())
    }

    // MARK: - Double Click

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }

    // MARK: - Drop Destination

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        .move
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty,
              let destinationURL = currentDirectoryURL
        else { return false }

        Task {
            do {
                try await fileSystemService.moveItems(from: urls, to: destinationURL)
                loadDirectory(at: destinationURL)
            } catch {
                showError(error)
            }
        }

        return true
    }
}

// MARK: - NSCollectionViewDelegateFlowLayout (Double-Click via Menu)

extension IconGridViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // Set up double-click action on the collection view
        let doubleClickGesture = NSClickGestureRecognizer(
            target: self, action: #selector(handleDoubleClick(_:))
        )
        doubleClickGesture.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClickGesture)

        // Right-click / context menu
        let menu = NSMenu()
        menu.delegate = self
        collectionView.menu = menu
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let location = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: location),
              sortedItems.indices.contains(indexPath.item)
        else { return }

        let item = sortedItems[indexPath.item]
        delegate?.iconGridView(self, didOpenItem: item)
    }
}

// MARK: - NSMenuDelegate

extension IconGridViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Handle lazy submenu population (Open With / Share).
        if let parentItem = menu.supermenu?.items.first(where: { $0.submenu === menu }),
           let fileItems = parentItem.representedObject as? [FileItem]
        {
            switch parentItem.title {
            case "Open With":
                FileListContextMenuBuilder.populateOpenWithSubmenu(menu, items: fileItems, target: self)
            case "Share":
                FileListContextMenuBuilder.populateShareSubmenu(menu, items: fileItems, target: self)
            default:
                break
            }
            return
        }

        // Main context menu.
        menu.removeAllItems()

        let items = selectedItems()
        let contextMenu: NSMenu
        if items.isEmpty {
            contextMenu = FileListContextMenuBuilder.buildBackgroundMenu(target: self)
        } else {
            delegate?.iconGridView(self, didRequestContextMenu: items)
            contextMenu = FileListContextMenuBuilder.buildContextMenu(
                items: items,
                target: self,
                menuDelegate: self
            )
        }
        let itemsToMove = contextMenu.items
        for item in itemsToMove {
            menu.addItem(item)
        }
    }
}
