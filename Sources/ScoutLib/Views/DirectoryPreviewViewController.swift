import AppKit

// MARK: - DirectoryPreviewViewController

/// Displays a directory's contents as an expandable tree using NSOutlineView.
/// Lazy-loads children on expand, caches results, and shows a collapsible metadata header.
final class DirectoryPreviewViewController: NSViewController, PreviewChild {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()
    private var scrollView: NSScrollView!
    private var outlineView: NSOutlineView!
    private var currentItem: FileItem?
    private var currentLoadTask: Task<Void, Never>?

    /// Called when the user double-clicks a directory to navigate into it.
    var onNavigate: ((URL) -> Void)?

    /// Cached directory contents keyed by URL.
    private var childrenCache: [URL: [FileItem]] = [:]
    private var expandTasks: [Task<Void, Never>] = []
    private let fileSystemService = FileSystemService.shared

    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Column Identifiers

    private static let nameColumnID = NSUserInterfaceItemIdentifier("name")
    private static let sizeColumnID = NSUserInterfaceItemIdentifier("size")

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configureOutlineView()

        view.addSubview(headerView)

        layoutSubviews()

        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.headerView.updateAppearance()
        }
    }

    // MARK: - Configuration

    private func configureOutlineView() {
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 16
        outlineView.autoresizesOutlineColumn = true
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.doubleAction = #selector(outlineViewDoubleClicked)
        outlineView.target = self
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self

        let nameColumn = NSTableColumn(identifier: Self.nameColumnID)
        nameColumn.title = "Name"
        nameColumn.minWidth = 120
        nameColumn.resizingMask = .autoresizingMask
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        let sizeColumn = NSTableColumn(identifier: Self.sizeColumnID)
        sizeColumn.title = "Size"
        sizeColumn.width = 60
        sizeColumn.minWidth = 40
        sizeColumn.maxWidth = 80
        sizeColumn.resizingMask = []
        outlineView.addTableColumn(sizeColumn)

        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = outlineView

        view.addSubview(scrollView)
    }

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Public API

    func displayItem(_ item: FileItem) {
        currentLoadTask?.cancel()
        expandTasks.forEach { $0.cancel() }
        expandTasks.removeAll()
        currentItem = item
        childrenCache.removeAll()

        headerView.update(with: item)

        currentLoadTask = Task { [weak self] in
            guard let self else { return }
            let children = await self.loadChildren(for: item.url)

            guard !Task.isCancelled, self.currentItem?.url == item.url else { return }

            let folderCount = children.filter(\.isDirectory).count
            let fileCount = children.count - folderCount

            var parts: [String] = []
            if folderCount > 0 { parts.append("\(folderCount) folder\(folderCount == 1 ? "" : "s")") }
            if fileCount > 0 { parts.append("\(fileCount) file\(fileCount == 1 ? "" : "s")") }

            await MainActor.run {
                self.headerView.setCompactDetail(parts.joined(separator: ", "))
                self.outlineView.reloadData()
            }

            // Auto-expand first-level directories. Snapshot the items first to
            // avoid iterating over outline rows that may shift during expansion.
            let directoryChildren = children.filter(\.isDirectory)
            for child in directoryChildren {
                guard !Task.isCancelled, self.currentItem?.url == item.url else { return }
                _ = await self.loadChildren(for: child.url)
                await MainActor.run {
                    self.outlineView.expandItem(child)
                }
            }
        }
    }

    func clear() {
        currentLoadTask?.cancel()
        expandTasks.forEach { $0.cancel() }
        expandTasks.removeAll()
        currentItem = nil
        childrenCache.removeAll()
        outlineView.reloadData()
    }

    // MARK: - Actions

    @objc private func outlineViewDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileItem else { return }
        if item.isDirectory {
            onNavigate?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - Private

    private func loadChildren(for url: URL) async -> [FileItem] {
        if let cached = childrenCache[url] { return cached }

        do {
            let items = try await fileSystemService.contentsOfDirectory(
                at: url, sortedBy: .name, order: .ascending, showHiddenFiles: true
            )
            childrenCache[url] = items
            return items
        } catch {
            childrenCache[url] = []
            return []
        }
    }

    private func cachedChildren(for url: URL) -> [FileItem] {
        childrenCache[url] ?? []
    }
}

// MARK: - NSOutlineViewDataSource

extension DirectoryPreviewViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            guard let root = currentItem else { return 0 }
            return cachedChildren(for: root.url).count
        }
        guard let fileItem = item as? FileItem, fileItem.isDirectory else { return 0 }
        return cachedChildren(for: fileItem.url).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let url: URL
        if let fileItem = item as? FileItem {
            url = fileItem.url
        } else {
            guard let root = currentItem else { return NSNull() }
            url = root.url
        }
        return cachedChildren(for: url)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        return fileItem.isDirectory
    }
}

// MARK: - NSOutlineViewDelegate

extension DirectoryPreviewViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fileItem = item as? FileItem else { return nil }

        if tableColumn?.identifier == Self.nameColumnID {
            let cellID = NSUserInterfaceItemIdentifier("NameCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = cellID

                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.imageScaling = .scaleProportionallyDown
                cell.addSubview(icon)
                cell.imageView = icon

                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.font = NSFont.systemFont(ofSize: 12)
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                cell.textField = text

                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.imageView?.image = fileItem.icon
            cell.textField?.stringValue = fileItem.name
            cell.alphaValue = fileItem.isHidden ? 0.5 : 1.0
            return cell
        }

        if tableColumn?.identifier == Self.sizeColumnID {
            let cellID = NSUserInterfaceItemIdentifier("SizeCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = cellID

                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.font = NSFont.systemFont(ofSize: 11)
                text.textColor = .secondaryLabelColor
                text.alignment = .right
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                cell.textField = text

                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = fileItem.isDirectory ? "" : fileItem.formattedSize
            cell.alphaValue = fileItem.isHidden ? 0.5 : 1.0
            return cell
        }

        return nil
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let fileItem = notification.userInfo?["NSObject"] as? FileItem else { return }

        if childrenCache[fileItem.url] == nil {
            let task = Task { [weak self] in
                guard let self else { return }
                _ = await self.loadChildren(for: fileItem.url)
                guard !Task.isCancelled, self.currentItem != nil else { return }
                await MainActor.run {
                    self.outlineView.reloadItem(fileItem, reloadChildren: true)
                }
            }
            expandTasks.append(task)
            // Remove completed tasks to prevent unbounded growth.
            expandTasks.removeAll { $0.isCancelled }
        }
    }
}

// MARK: - NSMenuDelegate (Context Menu)

extension DirectoryPreviewViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0, let item = outlineView.item(atRow: clickedRow) as? FileItem else { return }

        // Open
        let openItem = NSMenuItem(title: "Open", action: #selector(contextOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = item
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Get Info
        let infoItem = NSMenuItem(title: "Get Info", action: #selector(contextGetInfo(_:)), keyEquivalent: "")
        infoItem.target = self
        infoItem.representedObject = item
        menu.addItem(infoItem)

        // Copy Path
        let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(contextCopyPath(_:)), keyEquivalent: "")
        copyPathItem.target = self
        copyPathItem.representedObject = item
        menu.addItem(copyPathItem)

        menu.addItem(.separator())

        // Show in Finder
        let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(contextShowInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.representedObject = item
        menu.addItem(finderItem)
    }

    @objc private func contextOpen(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        if item.isDirectory {
            onNavigate?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func contextGetInfo(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        FinderHelper.showGetInfo(for: [item.url])
    }

    @objc private func contextCopyPath(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
    }

    @objc private func contextShowInFinder(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
