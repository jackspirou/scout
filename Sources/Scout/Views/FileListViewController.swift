import Cocoa
import UniformTypeIdentifiers

// MARK: - FileItem Convenience

private extension FileItem {
    /// Creates a FileItem from a URL by reading resource values, for use in the file list.
    init(url: URL) {
        let resourceValues = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .localizedTypeDescriptionKey,
            .effectiveIconKey,
            .isHiddenKey,
        ])

        self.init(
            url: url,
            name: url.lastPathComponent,
            isDirectory: resourceValues?.isDirectory ?? false,
            isHidden: resourceValues?.isHidden ?? url.lastPathComponent.hasPrefix("."),
            size: Int64(resourceValues?.fileSize ?? 0),
            modificationDate: resourceValues?.contentModificationDate ?? Date.distantPast,
            kind: resourceValues?.localizedTypeDescription ?? "Unknown",
            icon: (resourceValues?.effectiveIcon as? NSImage) ?? NSWorkspace.shared.icon(forFile: url.path)
        )
    }
}

// MARK: - FileListViewDelegate

protocol FileListViewDelegate: AnyObject {
    func fileListView(_ controller: FileListViewController, didSelectItems items: [FileItem])
    func fileListView(_ controller: FileListViewController, didOpenItem item: FileItem)
    func fileListView(_ controller: FileListViewController, didRequestContextMenu items: [FileItem])
    func fileListViewDidFinishLoading(_ controller: FileListViewController, itemCount: Int)
}

// MARK: - Sort Descriptor

private enum SortColumn: String {
    case name
    case dateModified
    case size
    case kind
}

// MARK: - Column Identifiers

private extension NSUserInterfaceItemIdentifier {
    static let nameColumn = NSUserInterfaceItemIdentifier("NameColumn")
    static let dateModifiedColumn = NSUserInterfaceItemIdentifier("DateModifiedColumn")
    static let sizeColumn = NSUserInterfaceItemIdentifier("SizeColumn")
    static let kindColumn = NSUserInterfaceItemIdentifier("KindColumn")
}

// MARK: - Drag Type

private extension NSPasteboard.PasteboardType {
    static let scoutFileItem = NSPasteboard.PasteboardType("com.scout.fileItem")
}

// MARK: - FileListViewController

final class FileListViewController: NSViewController {

    // MARK: - Properties

    weak var delegate: FileListViewDelegate?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var allItems: [FileItem] = []
    private var sortedItems: [FileItem] = []

    private var currentSortColumn: SortColumn = .name
    private var sortAscending: Bool = true

    private var loadingTask: Task<Void, Never>?

    /// The number of items currently displayed.
    var itemCount: Int { sortedItems.count }

    // MARK: - Date / Size Formatters

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        configureTableView()
        configureScrollView()
        layoutScrollView()
        registerForDragAndDrop()
    }

    // MARK: - Configuration

    private func configureTableView() {
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.headerView = NSTableHeaderView()
        tableView.doubleAction = #selector(tableViewDoubleClick(_:))
        tableView.target = self
        tableView.delegate = self
        tableView.dataSource = self

        addColumn(identifier: .nameColumn, title: "Name", width: 300, minWidth: 150, sortKey: "name")
        addColumn(identifier: .dateModifiedColumn, title: "Date Modified", width: 160, minWidth: 100, sortKey: "dateModified")
        addColumn(identifier: .sizeColumn, title: "Size", width: 80, minWidth: 60, sortKey: "size")
        addColumn(identifier: .kindColumn, title: "Kind", width: 120, minWidth: 80, sortKey: "kind")
    }

    private func addColumn(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        sortKey: String
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true)
        tableView.addTableColumn(column)
    }

    private func configureScrollView() {
        scrollView.documentView = tableView
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

    private func registerForDragAndDrop() {
        tableView.registerForDraggedTypes([.fileURL, .scoutFileItem])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    // MARK: - Public API

    /// Loads directory contents asynchronously.
    func loadDirectory(at url: URL) {
        loadingTask?.cancel()

        loadingTask = Task { [weak self] in
            guard let self else { return }

            let items = await Self.loadItems(at: url)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.allItems = items
                self.sortItems()
                self.tableView.reloadData()
                self.delegate?.fileListViewDidFinishLoading(self, itemCount: self.sortedItems.count)
            }
        }
    }

    /// Opens the currently selected item (used by keyboard navigation).
    func openSelectedItem() {
        let selectedRow = tableView.selectedRow
        guard sortedItems.indices.contains(selectedRow) else { return }
        delegate?.fileListView(self, didOpenItem: sortedItems[selectedRow])
    }

    // MARK: - Async Directory Loading

    private static func loadItems(at url: URL) async -> [FileItem] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                guard let urls = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isDirectoryKey,
                        .localizedTypeDescriptionKey,
                        .effectiveIconKey,
                    ],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: [])
                    return
                }

                let items = urls.map { FileItem(url: $0) }
                continuation.resume(returning: items)
            }
        }
    }

    // MARK: - Sorting

    private func sortItems() {
        sortedItems = allItems.sorted { lhs, rhs in
            // Directories always come first
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let result: Bool
            switch currentSortColumn {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .dateModified:
                result = lhs.dateModified < rhs.dateModified
            case .size:
                result = (lhs.size ?? 0) < (rhs.size ?? 0)
            case .kind:
                result = lhs.kind.localizedStandardCompare(rhs.kind) == .orderedAscending
            }

            return sortAscending ? result : !result
        }
    }

    // MARK: - Context Menu

    private func buildContextMenu(for items: [FileItem]) -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open", action: #selector(contextOpen(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let openWithItem = NSMenuItem(title: "Open With...", action: nil, keyEquivalent: "")
        let openWithSubmenu = NSMenu()
        openWithItem.submenu = openWithSubmenu
        menu.addItem(openWithItem)

        menu.addItem(NSMenuItem.separator())

        let getInfoItem = NSMenuItem(title: "Get Info", action: #selector(contextGetInfo(_:)), keyEquivalent: "")
        getInfoItem.target = self
        menu.addItem(getInfoItem)

        menu.addItem(NSMenuItem.separator())

        let renameItem = NSMenuItem(title: "Rename", action: #selector(contextRename(_:)), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(contextCopy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let cutItem = NSMenuItem(title: "Cut", action: #selector(contextCut(_:)), keyEquivalent: "")
        cutItem.target = self
        menu.addItem(cutItem)

        menu.addItem(NSMenuItem.separator())

        let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(contextMoveToTrash(_:)), keyEquivalent: "")
        trashItem.target = self
        menu.addItem(trashItem)

        let compressItem = NSMenuItem(title: "Compress", action: #selector(contextCompress(_:)), keyEquivalent: "")
        compressItem.target = self
        menu.addItem(compressItem)

        menu.addItem(NSMenuItem.separator())

        let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(contextNewFolder(_:)), keyEquivalent: "")
        newFolderItem.target = self
        menu.addItem(newFolderItem)

        // Tags submenu
        let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        let tagsSubmenu = NSMenu()
        for (label, color) in [("Red", NSColor.systemRed), ("Orange", NSColor.systemOrange),
                                ("Yellow", NSColor.systemYellow), ("Green", NSColor.systemGreen),
                                ("Blue", NSColor.systemBlue), ("Purple", NSColor.systemPurple),
                                ("Gray", NSColor.systemGray)] {
            let tagItem = NSMenuItem(title: label, action: #selector(contextSetTag(_:)), keyEquivalent: "")
            tagItem.target = self

            let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            tagItem.image = swatch
            tagsSubmenu.addItem(tagItem)
        }
        tagsItem.submenu = tagsSubmenu
        menu.addItem(tagsItem)

        return menu
    }

    // MARK: - Context Menu Actions

    @objc private func contextOpen(_ sender: NSMenuItem) {
        let items = selectedItems()
        for item in items {
            delegate?.fileListView(self, didOpenItem: item)
        }
    }

    @objc private func contextGetInfo(_ sender: NSMenuItem) {
        for item in selectedItems() {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard tableView.selectedRow >= 0 else { return }
        let columnIndex = tableView.column(withIdentifier: .nameColumn)
        guard columnIndex >= 0 else { return }
        tableView.editColumn(columnIndex, row: tableView.selectedRow, with: nil, select: true)
    }

    @objc private func contextCopy(_ sender: NSMenuItem) {
        let urls = selectedItems().map(\.url) as [NSURL]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
    }

    @objc private func contextCut(_ sender: NSMenuItem) {
        contextCopy(sender)
        // Mark items as cut for a future paste operation
    }

    @objc private func contextMoveToTrash(_ sender: NSMenuItem) {
        let items = selectedItems()
        for item in items {
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        // Reload after moving to trash
        if let currentDirectory = items.first?.url.deletingLastPathComponent() {
            loadDirectory(at: currentDirectory)
        }
    }

    @objc private func contextCompress(_ sender: NSMenuItem) {
        let urls = selectedItems().map(\.url)
        guard !urls.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        let archiveName = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent + ".zip" : "Archive.zip"
        let archivePath = urls[0].deletingLastPathComponent().appendingPathComponent(archiveName).path
        process.arguments = ["-r", archivePath] + urls.map(\.path)
        process.currentDirectoryURL = urls[0].deletingLastPathComponent()
        try? process.run()
    }

    @objc private func contextNewFolder(_ sender: NSMenuItem) {
        guard let firstItem = sortedItems.first else { return }
        let parentDir = firstItem.url.deletingLastPathComponent()
        let newFolderURL = parentDir.appendingPathComponent("untitled folder")
        try? FileManager.default.createDirectory(at: newFolderURL, withIntermediateDirectories: false)
        loadDirectory(at: parentDir)
    }

    @objc private func contextSetTag(_ sender: NSMenuItem) {
        // Tag application would go through an extended attribute API
    }

    // MARK: - Helpers

    private func selectedItems() -> [FileItem] {
        tableView.selectedRowIndexes.compactMap { index in
            sortedItems.indices.contains(index) ? sortedItems[index] : nil
        }
    }

    @objc private func tableViewDoubleClick(_ sender: Any?) {
        let clickedRow = tableView.clickedRow
        guard sortedItems.indices.contains(clickedRow) else { return }
        delegate?.fileListView(self, didOpenItem: sortedItems[clickedRow])
    }
}

// MARK: - NSTableViewDataSource

extension FileListViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        sortedItems.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key,
              let column = SortColumn(rawValue: key)
        else { return }

        currentSortColumn = column
        sortAscending = sortDescriptor.ascending
        sortItems()
        tableView.reloadData()
    }

    // MARK: - Drag Source

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard sortedItems.indices.contains(row) else { return nil }
        return sortedItems[row].url as NSURL
    }

    // MARK: - Drop Destination

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        // Allow drop on directories or between rows
        if dropOperation == .on, sortedItems.indices.contains(row), sortedItems[row].isDirectory {
            return .move
        }
        return dropOperation == .above ? .move : []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty
        else { return false }

        let destinationURL: URL
        if dropOperation == .on, sortedItems.indices.contains(row), sortedItems[row].isDirectory {
            destinationURL = sortedItems[row].url
        } else if let firstItem = sortedItems.first {
            destinationURL = firstItem.url.deletingLastPathComponent()
        } else {
            return false
        }

        for sourceURL in urls {
            let dest = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            try? FileManager.default.moveItem(at: sourceURL, to: dest)
        }

        loadDirectory(at: destinationURL)
        return true
    }
}

// MARK: - NSTableViewDelegate

extension FileListViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, sortedItems.indices.contains(row) else { return nil }
        let item = sortedItems[row]

        let cellIdentifier = column.identifier
        let cell: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier

            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField

            if cellIdentifier == .nameColumn {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                cell.addSubview(imageView)
                cell.imageView = imageView

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18),

                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            } else {
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
        }

        switch cellIdentifier {
        case .nameColumn:
            cell.textField?.stringValue = item.name
            cell.imageView?.image = item.icon
        case .dateModifiedColumn:
            cell.textField?.stringValue = Self.dateFormatter.string(from: item.dateModified)
        case .sizeColumn:
            cell.textField?.stringValue = item.isDirectory ? "--" : Self.sizeFormatter.string(fromByteCount: item.size ?? 0)
        case .kindColumn:
            cell.textField?.stringValue = item.kind
        default:
            break
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let items = selectedItems()
        delegate?.fileListView(self, didSelectItems: items)
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard edge == .trailing, sortedItems.indices.contains(row) else { return [] }

        let trashAction = NSTableViewRowAction(style: .destructive, title: "Trash") { [weak self] _, actionRow in
            guard let self, self.sortedItems.indices.contains(actionRow) else { return }
            let item = self.sortedItems[actionRow]
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            self.loadDirectory(at: item.url.deletingLastPathComponent())
        }

        return [trashAction]
    }

    // MARK: - Context Menu

    func tableView(_ tableView: NSTableView, menuForRows rows: IndexSet) -> NSMenu? {
        let items = rows.compactMap { sortedItems.indices.contains($0) ? sortedItems[$0] : nil }
        guard !items.isEmpty else { return nil }
        delegate?.fileListView(self, didRequestContextMenu: items)
        return buildContextMenu(for: items)
    }
}
