import AppKit

// MARK: - DirectoryPreviewViewController

/// Displays a directory's contents as an expandable tree using NSOutlineView.
/// Lazy-loads children on expand, caches results, and shows a collapsible metadata header.
final class DirectoryPreviewViewController: NSViewController {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()
    private var scrollView: NSScrollView!
    private var outlineView: NSOutlineView!
    private var currentItem: FileItem?
    private var currentLoadTask: Task<Void, Never>?

    /// Cached directory contents keyed by URL.
    private var childrenCache: [URL: [FileItem]] = [:]
    private var expandTasks: [Task<Void, Never>] = []
    private let fileSystemService = FileSystemService()

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
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self

        let nameColumn = NSTableColumn(identifier: Self.nameColumnID)
        nameColumn.title = "Name"
        nameColumn.minWidth = 120
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        let sizeColumn = NSTableColumn(identifier: Self.sizeColumnID)
        sizeColumn.title = "Size"
        sizeColumn.width = 60
        sizeColumn.minWidth = 40
        sizeColumn.maxWidth = 80
        outlineView.addTableColumn(sizeColumn)

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
            self.headerView.setCompactDetail(parts.joined(separator: ", "))

            self.outlineView.reloadData()

            // Auto-expand first-level directories. Snapshot the items first to
            // avoid iterating over outline rows that may shift during expansion.
            let directoryChildren = children.filter(\.isDirectory)
            for child in directoryChildren {
                guard !Task.isCancelled, self.currentItem?.url == item.url else { return }
                _ = await self.loadChildren(for: child.url)
                self.outlineView.expandItem(child)
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

    // MARK: - Private

    private func loadChildren(for url: URL) async -> [FileItem] {
        if let cached = childrenCache[url] { return cached }

        do {
            let items = try await fileSystemService.contentsOfDirectory(
                at: url, sortedBy: .name, order: .ascending, showHiddenFiles: false
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
                self.outlineView.reloadItem(fileItem, reloadChildren: true)
            }
            expandTasks.append(task)
        }
    }
}
