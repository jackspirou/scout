import Cocoa
import Quartz
import UniformTypeIdentifiers

// MARK: - ColumnBrowserViewDelegate

/// Delegate protocol for ColumnBrowserViewController, mirroring FileListViewDelegate callbacks.
protocol ColumnBrowserViewDelegate: AnyObject {
    func columnBrowserView(
        _ controller: ColumnBrowserViewController, didSelectItems items: [FileItem]
    )
    func columnBrowserView(
        _ controller: ColumnBrowserViewController, didOpenItem item: FileItem
    )
    func columnBrowserViewDidFinishLoading(
        _ controller: ColumnBrowserViewController, itemCount: Int
    )
}

// MARK: - ColumnData

/// Represents a single column in the Miller columns view.
private struct ColumnData {
    let url: URL
    var items: [FileItem]
    let tableView: NSTableView
    let scrollView: NSScrollView
}

// MARK: - ColumnBrowserViewController

final class ColumnBrowserViewController: NSViewController {
    // MARK: - Properties

    weak var delegate: ColumnBrowserViewDelegate?

    private let fileSystemService = FileSystemService.shared
    private let clipboardManager: ClipboardManager
    private var columns: [ColumnData] = []
    private(set) var currentDirectoryURL: URL?
    private var showHiddenFiles: Bool = false
    private var loadingTask: Task<Void, Never>?
    private var filterQuery: String = ""
    /// Unfiltered items for the last column, used to restore when the filter is cleared.
    private var unfilteredLastColumnItems: [FileItem] = []

    /// Routes Cmd+Z through the centralized FileUndoManager.
    override var undoManager: UndoManager? {
        FileUndoManager.shared.undoManager
    }

    private let outerScrollView = NSScrollView()
    private let stackView = NSStackView()

    // MARK: - Init

    init(clipboardManager: ClipboardManager) {
        self.clipboardManager = clipboardManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The number of items in the rightmost column.
    var itemCount: Int {
        columns.last?.items.count ?? 0
    }

    /// The items in the rightmost column.
    var currentItems: [FileItem] {
        columns.last?.items ?? []
    }

    // MARK: - Constants

    private enum Layout {
        static let columnWidth: CGFloat = 220
        static let rowHeight: CGFloat = 24
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        configureStackView()
        configureOuterScrollView()
        layoutOuterScrollView()
    }

    // MARK: - Configuration

    private func configureStackView() {
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.alignment = .top
        stackView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureOuterScrollView() {
        outerScrollView.documentView = stackView
        outerScrollView.hasVerticalScroller = false
        outerScrollView.hasHorizontalScroller = true
        outerScrollView.autohidesScrollers = true
        outerScrollView.translatesAutoresizingMaskIntoConstraints = false
        outerScrollView.drawsBackground = true
        view.addSubview(outerScrollView)
    }

    private func layoutOuterScrollView() {
        NSLayoutConstraint.activate([
            outerScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            outerScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            outerScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outerScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // The stack view fills the scroll view vertically
            stackView.topAnchor.constraint(equalTo: outerScrollView.contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: outerScrollView.contentView.bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// Loads the root column, clearing all existing columns.
    func loadDirectory(at url: URL) {
        currentDirectoryURL = url
        filterQuery = ""
        removeAllColumns()

        loadColumnAsync(for: url, atIndex: 0)
    }

    /// Returns the selected items from any column that has a selection,
    /// preferring the column that was most recently interacted with (rightmost with selection).
    func selectedItems() -> [FileItem] {
        for column in columns.reversed() {
            let selected = column.tableView.selectedRowIndexes.compactMap { index in
                column.items.indices.contains(index) ? column.items[index] : nil
            }
            if !selected.isEmpty {
                return selected
            }
        }
        return []
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

    /// Sets the filter query for live filtering of the last (deepest) column.
    func setFilterQuery(_ query: String) {
        filterQuery = query
        guard !columns.isEmpty else { return }
        let lastIndex = columns.count - 1
        let filtered: [FileItem]
        if filterQuery.isEmpty {
            filtered = unfilteredLastColumnItems
        } else {
            filtered = unfilteredLastColumnItems.filter {
                $0.name.localizedCaseInsensitiveContains(filterQuery)
            }
        }
        columns[lastIndex].items = filtered
        columns[lastIndex].tableView.reloadData()
        delegate?.columnBrowserViewDidFinishLoading(self, itemCount: filtered.count)
    }

    // MARK: - Column Management

    private func loadColumnAsync(for url: URL, atIndex columnIndex: Int) {
        loadingTask?.cancel()
        let showHidden = self.showHiddenFiles
        loadingTask = Task { [weak self] in
            guard let self else { return }

            let items = (try? await self.fileSystemService.contentsOfDirectory(
                at: url, sortedBy: .name, order: .ascending, showHiddenFiles: showHidden
            )) ?? []

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.addColumn(url: url, items: items, atIndex: columnIndex)
                self.delegate?.columnBrowserViewDidFinishLoading(self, itemCount: items.count)
            }
        }
    }

    private func addColumn(url: URL, items: [FileItem], atIndex columnIndex: Int) {
        // Remove any columns to the right of the new column index
        removeColumns(after: columnIndex - 1)

        let tableView = makeColumnTableView(columnIndex: columnIndex)
        let columnScrollView = makeColumnScrollView(for: tableView)

        let columnData = ColumnData(
            url: url,
            items: items,
            tableView: tableView,
            scrollView: columnScrollView
        )
        columns.append(columnData)
        unfilteredLastColumnItems = items

        // Add a separator before the column (unless it's the first)
        if columnIndex > 0 {
            let separator = makeSeparator()
            stackView.addArrangedSubview(separator)
        }
        stackView.addArrangedSubview(columnScrollView)

        tableView.reloadData()

        // Scroll to make the new column visible
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let visibleRect = columnScrollView.frame
            self.outerScrollView.contentView.scrollToVisible(visibleRect)
        }
    }

    private func removeColumns(after index: Int) {
        guard index + 1 < columns.count else { return }

        columns.removeSubrange((index + 1)...)

        // Rebuild the stack view from the remaining columns
        for subview in stackView.arrangedSubviews {
            subview.removeFromSuperview()
        }
        for (i, column) in columns.enumerated() {
            if i > 0 {
                stackView.addArrangedSubview(makeSeparator())
            }
            stackView.addArrangedSubview(column.scrollView)
        }
    }

    private func removeAllColumns() {
        columns.removeAll()
        for subview in stackView.arrangedSubviews {
            subview.removeFromSuperview()
        }
    }

    private func columnIndex(for tableView: NSTableView) -> Int? {
        columns.firstIndex(where: { $0.tableView === tableView })
    }

    // MARK: - Table View Factory

    private func makeColumnTableView(columnIndex: Int) -> NSTableView {
        let tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = Layout.rowHeight
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.tag = columnIndex
        tableView.doubleAction = #selector(columnTableViewDoubleClick(_:))
        tableView.target = self
        tableView.delegate = self
        tableView.dataSource = self

        let nameColumn = NSTableColumn(identifier: .nameColumn)
        nameColumn.title = "Name"
        nameColumn.width = Layout.columnWidth - 20
        tableView.addTableColumn(nameColumn)

        // Context menu
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        // Drag support
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        return tableView
    }

    private func makeColumnScrollView(for tableView: NSTableView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = true

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: Layout.columnWidth),
        ])

        return scrollView
    }

    private func makeSeparator() -> NSView {
        let separator = SeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor

        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])

        return separator
    }

    // MARK: - Menu Validation

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == NSSelectorFromString("contextRename:") {
            return selectedItems().count == 1
        }
        return true
    }

    // MARK: - Actions

    @objc private func columnTableViewDoubleClick(_ sender: NSTableView) {
        guard let colIdx = columnIndex(for: sender) else { return }
        let row = sender.clickedRow
        guard row >= 0, columns[colIdx].items.indices.contains(row) else { return }

        let item = columns[colIdx].items[row]
        delegate?.columnBrowserView(self, didOpenItem: item)
    }

    // MARK: - Context Menu Actions

    @objc func contextOpen(_ sender: NSMenuItem) {
        let items = selectedItems()
        for item in items {
            if item.isDirectory {
                delegate?.columnBrowserView(self, didOpenItem: item)
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

    @objc func contextRename(_ sender: Any?) {
        guard let item = selectedItems().first else { return }
        guard let newName = RenameHelper.showRenameDialog(for: item.name) else { return }

        Task {
            do {
                let newURL = try await fileSystemService.renameItem(at: item.url, to: newName)
                FileUndoManager.shared.recordRename(oldURL: item.url, newURL: newURL)
                if let dir = currentDirectoryURL {
                    loadDirectory(at: dir)
                }
            } catch {
                showError(error)
            }
        }
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

// MARK: - SeparatorView

/// A trivial NSView subclass used to identify separators in the stack view.
private class SeparatorView: NSView {}

// MARK: - NSTableViewDataSource

extension ColumnBrowserViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let colIdx = columnIndex(for: tableView) else { return 0 }
        return columns[colIdx].items.count
    }

    // MARK: - Drag Source

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard let colIdx = columnIndex(for: tableView),
              columns[colIdx].items.indices.contains(row)
        else { return nil }
        return columns[colIdx].items[row].url as NSURL
    }

    // MARK: - Drop Destination

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let colIdx = columnIndex(for: tableView) else { return [] }
        if dropOperation == .on,
           columns[colIdx].items.indices.contains(row),
           columns[colIdx].items[row].isDirectory
        {
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
        guard let colIdx = columnIndex(for: tableView),
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty
        else { return false }

        let destinationURL: URL
        if dropOperation == .on,
           columns[colIdx].items.indices.contains(row),
           columns[colIdx].items[row].isDirectory
        {
            destinationURL = columns[colIdx].items[row].url
        } else {
            destinationURL = columns[colIdx].url
        }

        Task {
            do {
                try await fileSystemService.moveItems(from: urls, to: destinationURL)
                if let dir = currentDirectoryURL {
                    loadDirectory(at: dir)
                }
            } catch {
                showError(error)
            }
        }

        return true
    }
}

// MARK: - NSTableViewDelegate

extension ColumnBrowserViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colIdx = columnIndex(for: tableView),
              columns[colIdx].items.indices.contains(row)
        else { return nil }

        let item = columns[colIdx].items[row]
        let cellIdentifier = NSUserInterfaceItemIdentifier("ColumnBrowserCell")

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.font = NSFont.systemFont(ofSize: 13)
            cell.addSubview(textField)
            cell.textField = textField

            // Chevron indicator for directories
            let chevron = NSImageView()
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.imageScaling = .scaleProportionallyDown
            chevron.identifier = NSUserInterfaceItemIdentifier("chevron")
            cell.addSubview(chevron)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                chevron.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                chevron.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 12),
                chevron.heightAnchor.constraint(equalToConstant: 12),
            ])
        }

        cell.imageView?.image = item.icon
        cell.textField?.stringValue = item.name
        cell.textField?.textColor = .labelColor

        // Show chevron for directories
        let chevronView = cell.subviews.first {
            $0.identifier == NSUserInterfaceItemIdentifier("chevron")
        } as? NSImageView
        if item.isDirectory {
            chevronView?.image = NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: "Directory"
            )
            chevronView?.contentTintColor = .tertiaryLabelColor
        } else {
            chevronView?.image = nil
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView,
              let colIdx = columnIndex(for: tableView)
        else { return }

        let row = tableView.selectedRow
        guard row >= 0, columns[colIdx].items.indices.contains(row) else { return }

        let selectedItem = columns[colIdx].items[row]

        // Cancel any in-flight column load before modifying columns
        loadingTask?.cancel()

        if selectedItem.isDirectory {
            // Load the directory into the next column, removing columns beyond
            removeColumns(after: colIdx)
            loadColumnAsync(for: selectedItem.url, atIndex: colIdx + 1)
        } else {
            // Just clear columns to the right
            removeColumns(after: colIdx)
            delegate?.columnBrowserView(self, didSelectItems: [selectedItem])
        }
    }
}

// MARK: - NSMenuDelegate

extension ColumnBrowserViewController: NSMenuDelegate {
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
