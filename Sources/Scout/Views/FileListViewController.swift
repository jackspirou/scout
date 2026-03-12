import Cocoa
import Quartz
import UniformTypeIdentifiers

// MARK: - FileListViewDelegate

protocol FileListViewDelegate: AnyObject {
    func fileListView(_ controller: FileListViewController, didSelectItems items: [FileItem])
    func fileListView(_ controller: FileListViewController, didOpenItem item: FileItem)
    func fileListView(_ controller: FileListViewController, didRequestContextMenu items: [FileItem])
    func fileListViewDidFinishLoading(_ controller: FileListViewController, itemCount: Int)
}

// MARK: - Column Identifiers

extension NSUserInterfaceItemIdentifier {
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
    private let tableView = FileListTableView()
    private let fileSystemService = FileSystemService()
    private let clipboardManager: ClipboardManager

    private var iconStyle: IconStyle
    private var allItems: [FileItem] = []
    private var sortedItems: [FileItem] = []
    private var urlToIndex: [URL: Int] = [:]

    private var currentSortField: SortField = .name
    private var sortAscending: Bool = true

    private var loadingTask: Task<Void, Never>?

    /// The URL of the directory currently displayed.
    private(set) var currentDirectoryURL: URL?

    // MARK: - Init

    init(clipboardManager: ClipboardManager = ClipboardManager(), iconStyle: IconStyle = .system) {
        self.iconStyle = iconStyle
        self.clipboardManager = clipboardManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The number of items currently displayed.
    var itemCount: Int {
        sortedItems.count
    }

    /// The items currently displayed, for external consumers such as the directory monitor.
    var currentItems: [FileItem] {
        sortedItems
    }

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
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.headerView = NSTableHeaderView()
        tableView.doubleAction = #selector(tableViewDoubleClick(_:))
        tableView.target = self
        tableView.delegate = self
        tableView.dataSource = self

        addColumn(identifier: .nameColumn, title: "Name", width: 300, minWidth: 150, sortKey: .name)
        addColumn(
            identifier: .dateModifiedColumn,
            title: "Date Modified",
            width: 160,
            minWidth: 100,
            sortKey: .dateModified
        )
        addColumn(identifier: .sizeColumn, title: "Size", width: 80, minWidth: 60, sortKey: .size)
        addColumn(identifier: .kindColumn, title: "Kind", width: 120, minWidth: 80, sortKey: .kind)

        tableView.contextMenuProvider = { [weak self] rows in
            self?.buildContextMenu(forRows: rows)
        }

        tableView.backgroundMenuProvider = { [weak self] in
            self?.buildBackgroundMenu()
        }
    }

    private func addColumn(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        sortKey: SortField
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey.rawValue, ascending: true)
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
        currentDirectoryURL = url
        loadingTask?.cancel()

        loadingTask = Task { [weak self] in
            guard let self else { return }

            let items = (try? await self.fileSystemService.contentsOfDirectory(at: url)) ?? []

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.allItems = items
                self.sortItems()
                self.tableView.reloadData()
                self.delegate?.fileListViewDidFinishLoading(self, itemCount: self.sortedItems.count)
            }
        }
    }

    /// Updates the icon style and reloads the current directory if one is loaded.
    func setIconStyle(_ style: IconStyle) {
        iconStyle = style
        Task { await fileSystemService.setIconStyle(style) }
        if let url = currentDirectoryURL {
            loadDirectory(at: url)
        }
    }

    /// Opens the currently selected item (used by keyboard navigation).
    func openSelectedItem() {
        let selectedRow = tableView.selectedRow
        guard sortedItems.indices.contains(selectedRow) else { return }
        delegate?.fileListView(self, didOpenItem: sortedItems[selectedRow])
    }

    /// Toggles the Quick Look preview panel for the current selection.
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Responder Chain Actions (Main Menu Shortcuts)

    /// Cmd+C — copies selected files to the pasteboard.
    @objc func copy(_ sender: Any?) {
        let urls = selectedItems().map(\.url)
        guard !urls.isEmpty else { return }
        clipboardManager.copy(urls: urls)
    }

    /// Cmd+X — cuts selected files (copy + mark for move).
    @objc func cut(_ sender: Any?) {
        let urls = selectedItems().map(\.url)
        guard !urls.isEmpty else { return }
        clipboardManager.cut(urls: urls)

        for row in tableView.selectedRowIndexes {
            if let cellView = tableView.view(
                atColumn: tableView.column(withIdentifier: .nameColumn),
                row: row,
                makeIfNecessary: false
            ) as? NSTableCellView {
                cellView.imageView?.alphaValue = 0.5
            }
        }
    }

    /// Cmd+V — pastes files from the pasteboard into the current directory.
    @objc func paste(_ sender: Any?) {
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

    /// Cmd+Delete — moves selected files to Trash.
    @objc func moveToTrash(_ sender: Any?) {
        let items = selectedItems()
        guard !items.isEmpty else { return }
        Task {
            do {
                _ = try await fileSystemService.trashItems(urls: items.map(\.url))
                if let dir = currentDirectoryURL {
                    loadDirectory(at: dir)
                }
            } catch {
                showError(error)
            }
        }
    }

    /// Cmd+D — duplicates selected files.
    @objc func duplicateSelection(_ sender: Any?) {
        let items = selectedItems()
        guard !items.isEmpty else { return }

        let urls = items.map(\.url)
        let dir = currentDirectoryURL
        Task {
            let firstError: (any Error)? = await Task.detached {
                let fm = FileManager.default
                var error: (any Error)?
                for url in urls {
                    let parentDir = url.deletingLastPathComponent()
                    let baseName = url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension
                    let copyName = ext.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(ext)"
                    let destURL = parentDir.appendingPathComponent(copyName)
                    do {
                        try fm.copyItem(at: url, to: destURL)
                    } catch let e {
                        if error == nil { error = e }
                    }
                }
                return error
            }.value
            if let firstError {
                showError(firstError)
            }
            if let dir {
                loadDirectory(at: dir)
            }
        }
    }

    /// F2 — starts renaming the selected item.
    @objc func renameSelection(_ sender: Any?) {
        guard tableView.selectedRow >= 0 else { return }
        let columnIndex = tableView.column(withIdentifier: .nameColumn)
        guard columnIndex >= 0 else { return }
        tableView.editColumn(columnIndex, row: tableView.selectedRow, with: nil, select: true)
    }

    /// Cmd+Shift+N — creates a new folder in the current directory.
    @objc func newFolder(_ sender: Any?) {
        guard let dir = currentDirectoryURL else { return }
        Task {
            do {
                _ = try await fileSystemService.createDirectory(at: dir, named: "untitled folder")
                loadDirectory(at: dir)
            } catch {
                showError(error)
            }
        }
    }

    // MARK: - Sorting

    private func sortItems() {
        sortedItems = allItems.sorted { lhs, rhs in
            let result = FileItem.compare(lhs, rhs, by: currentSortField)
            return sortAscending ? result : !result
        }
        rebuildURLIndex()
    }

    /// Rebuilds the URL-to-row-index lookup dictionary from the current sorted items.
    private func rebuildURLIndex() {
        urlToIndex.removeAll(keepingCapacity: true)
        for (index, item) in sortedItems.enumerated() {
            urlToIndex[item.url] = index
        }
    }

    /// Returns the correct insertion index for a new item in sortedItems using binary search.
    private func sortedInsertionIndex(for newItem: FileItem) -> Int {
        var low = 0
        var high = sortedItems.count
        while low < high {
            let mid = (low + high) / 2
            let existing = sortedItems[mid]

            let result = FileItem.compare(newItem, existing, by: currentSortField)
            let newItemFirst = sortAscending ? result : !result

            if newItemFirst {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    // MARK: - Incremental Updates

    /// Applies file system change events incrementally to the table view, preserving selection.
    /// Falls back to a full reload when total changes exceed 50 items.
    func applyChanges(_ events: [DirectoryChangeEvent]) {
        // Count total changes to decide whether to do incremental or full reload.
        var totalChanges = 0
        for event in events {
            switch event {
            case let .itemsAdded(urls): totalChanges += urls.count
            case let .itemsRemoved(urls): totalChanges += urls.count
            case let .itemsModified(urls): totalChanges += urls.count
            case .rootChanged: totalChanges += 100 // Force full reload
            }
        }

        if totalChanges > 50 {
            if let url = currentDirectoryURL {
                loadDirectory(at: url)
            }
            return
        }

        // Handle rootChanged by doing a full reload.
        for event in events {
            if case .rootChanged = event {
                if let url = currentDirectoryURL {
                    loadDirectory(at: url)
                }
                return
            }
        }

        // Save selected URLs to restore after updates.
        let selectedURLs = Set(tableView.selectedRowIndexes.compactMap { index -> URL? in
            sortedItems.indices.contains(index) ? sortedItems[index].url : nil
        })

        tableView.beginUpdates()

        // Process removals first (in reverse index order to keep indexes stable).
        for event in events {
            guard case let .itemsRemoved(urls) = event else { continue }

            var indexesToRemove: [Int] = []
            for url in urls {
                if let index = urlToIndex[url] {
                    indexesToRemove.append(index)
                }
            }
            // Sort descending so we remove from the end first.
            indexesToRemove.sort(by: >)
            for index in indexesToRemove {
                let item = sortedItems[index]
                allItems.removeAll { $0.url == item.url }
                sortedItems.remove(at: index)
                tableView.removeRows(at: IndexSet(integer: index), withAnimation: .effectFade)
            }
        }

        // Rebuild index after removals before processing additions.
        rebuildURLIndex()

        // Process additions.
        for event in events {
            guard case let .itemsAdded(urls) = event else { continue }

            for url in urls {
                // Skip if already present (avoid duplicates).
                guard urlToIndex[url] == nil else { continue }

                guard let newItem = FileItem.create(from: url, iconStyle: iconStyle) else { continue }
                // Skip hidden files to match loadDirectory behavior.
                if newItem.isHidden { continue }

                allItems.append(newItem)
                let insertionIndex = sortedInsertionIndex(for: newItem)
                sortedItems.insert(newItem, at: insertionIndex)
                tableView.insertRows(at: IndexSet(integer: insertionIndex), withAnimation: .effectGap)

                // Update index inline: shift entries at or after the insertion point, then add the new entry.
                for (existingURL, existingIndex) in urlToIndex where existingIndex >= insertionIndex {
                    urlToIndex[existingURL] = existingIndex + 1
                }
                urlToIndex[url] = insertionIndex
            }
        }

        // Process modifications.
        for event in events {
            guard case let .itemsModified(urls) = event else { continue }

            for url in urls {
                guard let index = urlToIndex[url] else { continue }
                // Refresh metadata by creating a new FileItem.
                guard let refreshedItem = FileItem.create(from: url, iconStyle: iconStyle) else { continue }
                // Skip hidden files.
                if refreshedItem.isHidden { continue }

                // Replace in allItems.
                if let allIndex = allItems.firstIndex(where: { $0.url == url }) {
                    allItems[allIndex] = refreshedItem
                }
                sortedItems[index] = refreshedItem
                let allColumnIndexes = IndexSet(integersIn: 0 ..< tableView.numberOfColumns)
                tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: allColumnIndexes)
            }
        }

        tableView.endUpdates()

        // Rebuild the full index after all changes.
        rebuildURLIndex()

        // Restore selection.
        var newSelectionIndexes = IndexSet()
        for url in selectedURLs {
            if let index = urlToIndex[url] {
                newSelectionIndexes.insert(index)
            }
        }
        if !newSelectionIndexes.isEmpty {
            tableView.selectRowIndexes(newSelectionIndexes, byExtendingSelection: false)
        }

        // Notify delegate of updated item count.
        delegate?.fileListViewDidFinishLoading(self, itemCount: sortedItems.count)
    }

    // MARK: - Context Menu

    /// Builds a context menu for the given row indexes, mapping them to FileItem instances.
    private func buildContextMenu(forRows rows: IndexSet) -> NSMenu? {
        let items = rows.compactMap { sortedItems.indices.contains($0) ? sortedItems[$0] : nil }
        guard !items.isEmpty else { return nil }

        delegate?.fileListView(self, didRequestContextMenu: items)

        return FileListContextMenuBuilder.buildContextMenu(
            items: items,
            target: self,
            menuDelegate: self
        )
    }

    /// Builds a background context menu shown when right-clicking on empty space.
    private func buildBackgroundMenu() -> NSMenu {
        FileListContextMenuBuilder.buildBackgroundMenu(target: self)
    }

    // MARK: - Context Menu Actions

    @objc func contextOpen(_ sender: NSMenuItem) {
        let items = selectedItems()
        for item in items {
            if item.isDirectory {
                delegate?.fileListView(self, didOpenItem: item)
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
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func contextRename(_ sender: NSMenuItem) {
        renameSelection(sender)
    }

    @objc func contextCopy(_ sender: NSMenuItem) {
        copy(sender)
    }

    @objc func contextCut(_ sender: NSMenuItem) {
        cut(sender)
    }

    @objc func contextPaste(_ sender: NSMenuItem) {
        paste(sender)
    }

    @objc func contextDuplicate(_ sender: NSMenuItem) {
        duplicateSelection(sender)
    }

    @objc func contextMoveToTrash(_ sender: NSMenuItem) {
        moveToTrash(sender)
    }

    @objc func contextCopyPath(_ sender: NSMenuItem) {
        copyPathOfSelection(sender)
    }

    /// Copies the file path(s) of the current selection to the clipboard.
    /// Exposed to the responder chain for the main menu Cmd+Opt+C shortcut.
    @objc func copyPathOfSelection(_ sender: Any?) {
        let paths = selectedItems().map(\.url.path)
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func contextQuickLook(_ sender: NSMenuItem) {
        toggleQuickLook()
    }

    @objc func contextShowInFinder(_ sender: NSMenuItem) {
        let urls = selectedItems().map(\.url)
        if urls.isEmpty {
            // Background context: reveal the current directory itself.
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
        try? process.run()
    }

    @objc func contextNewFolder(_ sender: NSMenuItem) {
        newFolder(sender)
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

    func selectedItems() -> [FileItem] {
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
              let column = SortField(rawValue: key)
        else { return }

        currentSortField = column
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
                    imageView.widthAnchor.constraint(equalToConstant: 20),
                    imageView.heightAnchor.constraint(equalToConstant: 20),

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

        let monospacedFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        switch cellIdentifier {
        case .nameColumn:
            cell.textField?.stringValue = item.name
            cell.textField?.font = NSFont.systemFont(ofSize: 13)
            cell.textField?.textColor = .labelColor
            cell.imageView?.image = item.icon
        case .dateModifiedColumn:
            cell.textField?.stringValue = Self.dateFormatter.string(from: item.dateModified)
            cell.textField?.font = monospacedFont
            cell.textField?.textColor = .secondaryLabelColor
        case .sizeColumn:
            cell.textField?.stringValue = item.isDirectory ? "--" : Self.sizeFormatter
                .string(fromByteCount: item.size ?? 0)
            cell.textField?.font = monospacedFont
            cell.textField?.textColor = .secondaryLabelColor
        case .kindColumn:
            cell.textField?.stringValue = item.kind
            cell.textField?.font = monospacedFont
            cell.textField?.textColor = .secondaryLabelColor
        default:
            break
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let items = selectedItems()
        delegate?.fileListView(self, didSelectItems: items)
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int,
                   edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction]
    {
        guard edge == .trailing, sortedItems.indices.contains(row) else { return [] }

        let trashAction = NSTableViewRowAction(style: .destructive, title: "Trash") { [weak self] _, actionRow in
            guard let self, self.sortedItems.indices.contains(actionRow) else { return }
            let item = self.sortedItems[actionRow]
            Task {
                do {
                    _ = try await self.fileSystemService.trashItems(urls: [item.url])
                    self.loadDirectory(at: item.url.deletingLastPathComponent())
                } catch {
                    self.showError(error)
                }
            }
        }

        return [trashAction]
    }
}

// MARK: - NSMenuDelegate (Lazy Submenu Population)

extension FileListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Identify which submenu this is by checking the parent item's title.
        guard let parentItem = menu.supermenu?.items.first(where: { $0.submenu === menu }),
              let items = parentItem.representedObject as? [FileItem]
        else { return }

        switch parentItem.title {
        case "Open With":
            FileListContextMenuBuilder.populateOpenWithSubmenu(menu, items: items, target: self)
        case "Share":
            FileListContextMenuBuilder.populateShareSubmenu(menu, items: items, target: self)
        default:
            break
        }
    }
}

// MARK: - QLPreviewPanel Support

extension FileListViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        let selected = selectedItems()
        return selected.isEmpty ? 0 : selected.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let selected = selectedItems()
        guard selected.indices.contains(index) else { return nil }
        return selected[index].url as NSURL
    }
}
