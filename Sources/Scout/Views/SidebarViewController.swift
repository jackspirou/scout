import Cocoa

// MARK: - SidebarViewController

final class SidebarViewController: NSViewController {
    // MARK: - Properties

    var onNavigate: ((URL) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    private var sectionItems: [SidebarSection: [SidebarItem]] = [:]
    private let sections = SidebarSection.allCases

    /// Built-in favorite URLs that cannot be removed via context menu.
    private var defaultFavoriteURLs: Set<URL> {
        Set(builtInFavorites().map(\.url))
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        configureScrollView()
        configureOutlineView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadAllSections()
        observeVolumeNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configuration

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.title = "Sidebar"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = true
        outlineView.indentationPerLevel = 14

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineViewClicked(_:))

        // Register for drag-drop of file URLs onto Favorites
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.every, forLocal: false)

        // Context menu
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
    }

    // MARK: - Data Loading

    func reloadAllSections() {
        sectionItems[.favorites] = loadFavorites()
        sectionItems[.iCloud] = loadICloud()
        sectionItems[.locations] = loadLocations()
        sectionItems[.tags] = loadTags()
        outlineView.reloadData()

        // Expand all sections by default
        for section in sections {
            outlineView.expandItem(section)
        }
    }

    // MARK: - Favorites

    private func builtInFavorites() -> [SidebarItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let entries: [(String, String, URL)] = [
            ("Home", "house", home),
            ("Desktop", "menubar.dock.rectangle", home.appendingPathComponent("Desktop")),
            ("Documents", "doc", home.appendingPathComponent("Documents")),
            ("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads")),
            ("Applications", "app.dashed", URL(fileURLWithPath: "/Applications")),
        ]

        return entries.compactMap { name, symbol, url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
                ?? NSWorkspace.shared.icon(forFile: url.path)
            return SidebarItem(url: url, name: name, icon: icon, section: .favorites)
        }
    }

    private func loadFavorites() -> [SidebarItem] {
        let builtIn = builtInFavorites()
        var items = builtIn
        let userURLs = PersistenceService.shared.loadSidebarFavorites()
        let builtInSet = Set(builtIn.map(\.url))
        for url in userURLs where !builtInSet.contains(url) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let name = url.lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            items.append(SidebarItem(url: url, name: name, icon: icon, section: .favorites))
        }
        return items
    }

    // MARK: - iCloud

    private func loadICloud() -> [SidebarItem] {
        let iCloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: iCloudDocs.path) else { return [] }
        let icon = NSImage(systemSymbolName: "icloud", accessibilityDescription: "iCloud Drive")
            ?? NSWorkspace.shared.icon(forFile: iCloudDocs.path)
        return [SidebarItem(url: iCloudDocs, name: "iCloud Drive", icon: icon, section: .iCloud)]
    }

    // MARK: - Locations

    private func loadLocations() -> [SidebarItem] {
        let keys: [URLResourceKey] = [.volumeNameKey, .effectiveIconKey]
        guard
            let volumes = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes]
            )
        else {
            return []
        }

        return volumes.compactMap { volumeURL in
            let values = try? volumeURL.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? volumeURL.lastPathComponent
            let icon = (values?.effectiveIcon as? NSImage)
                ?? NSWorkspace.shared.icon(forFile: volumeURL.path)
            return SidebarItem(url: volumeURL, name: name, icon: icon, section: .locations)
        }
    }

    // MARK: - Tags

    private func loadTags() -> [SidebarItem] {
        let labels = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors

        var items: [SidebarItem] = []
        for (index, label) in labels.enumerated() where !label.isEmpty {
            let color = index < colors.count ? colors[index] : NSColor.labelColor
            let icon = makeTagIcon(color: color)
            // Tags don't have a real URL, use a synthetic one
            let tagURL = URL(fileURLWithPath: "/tags/\(label)")
            items.append(SidebarItem(url: tagURL, name: label, icon: icon, section: .tags))
        }
        return items
    }

    private func makeTagIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Volume Notifications

    private func observeVolumeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(volumesChanged(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(volumesChanged(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    @objc private func volumesChanged(_ notification: Notification) {
        sectionItems[.locations] = loadLocations()
        outlineView.reloadItem(SidebarSection.locations, reloadChildren: true)
        outlineView.expandItem(SidebarSection.locations)
    }

    // MARK: - Actions

    @objc private func outlineViewClicked(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0 else { return }
        let item = sender.item(atRow: row)
        if let sidebarItem = item as? SidebarItem {
            onNavigate?(sidebarItem.url)
        }
    }

    // MARK: - User Favorites Management

    private func addUserFavorite(url: URL) {
        var userURLs = PersistenceService.shared.loadSidebarFavorites()
        guard !userURLs.contains(url), !defaultFavoriteURLs.contains(url) else { return }
        userURLs.append(url)
        PersistenceService.shared.saveSidebarFavorites(userURLs)
        sectionItems[.favorites] = loadFavorites()
        outlineView.reloadItem(SidebarSection.favorites, reloadChildren: true)
        outlineView.expandItem(SidebarSection.favorites)
    }

    private func removeUserFavorite(url: URL) {
        var userURLs = PersistenceService.shared.loadSidebarFavorites()
        userURLs.removeAll { $0 == url }
        PersistenceService.shared.saveSidebarFavorites(userURLs)
        sectionItems[.favorites] = loadFavorites()
        outlineView.reloadItem(SidebarSection.favorites, reloadChildren: true)
        outlineView.expandItem(SidebarSection.favorites)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sections.count
        }
        if let section = item as? SidebarSection {
            return sectionItems[section]?.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sections[index]
        }
        if let section = item as? SidebarSection {
            return sectionItems[section]![index]
        }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }

    // MARK: Drag-Drop

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Only accept drops on the Favorites section
        if let section = item as? SidebarSection, section == .favorites {
            guard let pasteboard = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !pasteboard.isEmpty else {
                return []
            }
            return .link
        }
        return []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
        else {
            return false
        }

        for url in urls {
            addUserFavorite(url: url)
        }
        return true
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        if let section = item as? SidebarSection {
            let identifier = NSUserInterfaceItemIdentifier("SidebarHeaderCell")
            let cellView =
                outlineView.makeView(withIdentifier: identifier, owner: self)
                    as? NSTableCellView ?? NSTableCellView()
            cellView.identifier = identifier

            let textField = cellView.textField ?? {
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
                tf.textColor = .secondaryLabelColor
                cellView.addSubview(tf)
                cellView.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                    tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
                return tf
            }()
            textField.stringValue = section.rawValue.uppercased()
            return cellView
        }

        if let sidebarItem = item as? SidebarItem {
            let identifier = NSUserInterfaceItemIdentifier("SidebarItemCell")
            let cellView =
                outlineView.makeView(withIdentifier: identifier, owner: self)
                    as? NSTableCellView ?? NSTableCellView()
            cellView.identifier = identifier

            let imageView = cellView.imageView ?? {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                cellView.addSubview(iv)
                cellView.imageView = iv
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                ])
                return iv
            }()
            imageView.image = sidebarItem.icon

            let textField = cellView.textField ?? {
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                tf.lineBreakMode = .byTruncatingTail
                cellView.addSubview(tf)
                cellView.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
                return tf
            }()
            textField.stringValue = sidebarItem.name

            return cellView
        }

        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarItem
    }
}

// MARK: - NSMenuDelegate

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }

        // Only show "Remove from Sidebar" for user-added favorites
        guard item.section == .favorites, !defaultFavoriteURLs.contains(item.url) else { return }

        let removeItem = NSMenuItem(
            title: "Remove from Sidebar",
            action: #selector(removeFromSidebar(_:)),
            keyEquivalent: ""
        )
        removeItem.target = self
        removeItem.representedObject = item
        menu.addItem(removeItem)
    }

    @objc private func removeFromSidebar(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem else { return }
        removeUserFavorite(url: item.url)
    }
}
