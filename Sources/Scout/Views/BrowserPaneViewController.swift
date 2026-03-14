import Cocoa

// MARK: - BrowserPaneDelegate

protocol BrowserPaneDelegate: AnyObject {
    func browserPane(_ pane: BrowserPaneViewController, didSelectItems items: [FileItem])
}

// MARK: - BrowserPaneViewController

final class BrowserPaneViewController: NSViewController {
    // MARK: - Properties

    weak var delegate: BrowserPaneDelegate?

    /// Called on spacebar press. Return `true` if handled (e.g. audio play/pause), `false` to fall through to Quick Look.
    var onSpacebarPressed: (() -> Bool)?

    private var tabs: [BrowserTabState] = []
    private(set) var activeTabIndex: Int = 0
    private var isActive: Bool = false

    private var iconStyle: IconStyle
    private var showHiddenFiles: Bool
    private(set) var currentViewMode: ViewMode = .list
    private var suppressSelectionClear: Bool = false
    private let tabBar = NSStackView()
    private let pathBarView = PathBarView()
    private let fileListViewController: FileListViewController
    private let statusBar = NSTextField(labelWithString: "0 items")
    private let directoryMonitor = DirectoryMonitor()

    /// Container view that holds whichever view mode is active (list, icon grid, or column).
    private let contentContainerView = NSView()

    private lazy var iconGridViewController: IconGridViewController = {
        let vc = IconGridViewController()
        vc.delegate = self
        return vc
    }()

    private lazy var columnBrowserViewController: ColumnBrowserViewController = {
        let vc = ColumnBrowserViewController()
        vc.delegate = self
        return vc
    }()

    // MARK: - Init

    init(clipboardManager: ClipboardManager, iconStyle: IconStyle = .system, showHiddenFiles: Bool = true) {
        self.iconStyle = iconStyle
        self.showHiddenFiles = showHiddenFiles
        fileListViewController = FileListViewController(clipboardManager: clipboardManager, iconStyle: iconStyle, showHiddenFiles: showHiddenFiles)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var tabBarHeightConstraint: NSLayoutConstraint?

    /// A thin accent-colored bar pinned to the top edge that indicates the active pane.
    private lazy var activeIndicatorBar: NSView = {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        bar.isHidden = true
        return bar
    }()

    /// The number of open tabs.
    var tabCount: Int {
        tabs.count
    }

    // MARK: - Constants

    private enum Layout {
        static let tabBarHeight: CGFloat = 28
        static let statusBarHeight: CGFloat = 22
        static let pathBarHeight: CGFloat = 30
        static let activeIndicatorHeight: CGFloat = 2
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        configureTabBar()
        configurePathBar()
        configureFileList()
        configureStatusBar()
        configureActiveIndicator()
        layoutSubviews()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Open the home directory in the first tab by default
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        addTab(url: homeURL)

        pathBarView.delegate = self
        pathBarView.setIconStyle(iconStyle)
        fileListViewController.delegate = self
        directoryMonitor.delegate = self
    }

    /// Returns the currently selected items from whichever view mode is active.
    func selectedItems() -> [FileItem] {
        switch currentViewMode {
        case .list:
            return fileListViewController.selectedItems()
        case .icon:
            return iconGridViewController.selectedItems()
        case .column:
            return columnBrowserViewController.selectedItems()
        case .gallery:
            return fileListViewController.selectedItems()
        }
    }

    // MARK: - Configuration

    private func configureTabBar() {
        tabBar.orientation = .horizontal
        tabBar.distribution = .fillProportionally
        tabBar.spacing = 1
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.wantsLayer = true
        view.addSubview(tabBar)
    }

    private func configurePathBar() {
        pathBarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pathBarView)
    }

    private func configureFileList() {
        // Set up the content container that will hold the active view mode
        contentContainerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainerView)

        // Start with the file list view controller as the default
        addChild(fileListViewController)
        fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
        embedViewInContainer(fileListViewController.view)
    }

    private func configureStatusBar() {
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.font = NSFont.systemFont(ofSize: 11)
        statusBar.textColor = NSColor.secondaryLabelColor
        statusBar.isEditable = false
        statusBar.isBezeled = false
        statusBar.drawsBackground = false
        statusBar.alignment = .left
        statusBar.lineBreakMode = .byTruncatingTail
        view.addSubview(statusBar)
    }

    private func configureActiveIndicator() {
        view.addSubview(activeIndicatorBar)
    }

    private func layoutSubviews() {
        let heightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 0)
        tabBarHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            // Tab bar at the very top (hidden by default for single tab)
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heightConstraint,

            // Path bar below tab bar
            pathBarView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            pathBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pathBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pathBarView.heightAnchor.constraint(equalToConstant: Layout.pathBarHeight),

            // Content container fills the middle (hosts list, icon grid, or column view)
            contentContainerView.topAnchor.constraint(equalTo: pathBarView.bottomAnchor),
            contentContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainerView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Status bar at the bottom
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Layout.statusBarHeight),

            // Active-pane indicator pinned to top edge
            activeIndicatorBar.topAnchor.constraint(equalTo: view.topAnchor),
            activeIndicatorBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            activeIndicatorBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            activeIndicatorBar.heightAnchor.constraint(equalToConstant: Layout.activeIndicatorHeight),
        ])
    }

    // MARK: - Public API

    /// Navigate the current tab to the given URL.
    func navigateTo(url: URL) {
        guard !tabs.isEmpty else { return }

        var tab = tabs[activeTabIndex]
        tab.backStack.append(tab.url)
        tab.forwardStack.removeAll()
        tab.url = url
        tab.title = url.lastPathComponent
        tabs[activeTabIndex] = tab

        reloadCurrentTab()
    }

    /// Navigate back in the current tab's history.
    func goBack() {
        guard !tabs.isEmpty else { return }
        var tab = tabs[activeTabIndex]
        guard let previousURL = tab.backStack.popLast() else { return }

        tab.forwardStack.append(tab.url)
        tab.url = previousURL
        tab.title = previousURL.lastPathComponent
        tabs[activeTabIndex] = tab

        reloadCurrentTab()
    }

    /// Navigate forward in the current tab's history.
    func goForward() {
        guard !tabs.isEmpty else { return }
        var tab = tabs[activeTabIndex]
        guard let nextURL = tab.forwardStack.popLast() else { return }

        tab.backStack.append(tab.url)
        tab.url = nextURL
        tab.title = nextURL.lastPathComponent
        tabs[activeTabIndex] = tab

        reloadCurrentTab()
    }

    /// Navigate to the parent directory.
    func goToParent() {
        guard !tabs.isEmpty else { return }
        let parentURL = tabs[activeTabIndex].url.deletingLastPathComponent()
        navigateTo(url: parentURL)
    }

    /// Add a new tab pointing to the given URL and switch to it.
    func addTab(url: URL) {
        let tab = BrowserTabState(url: url)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        rebuildTabBar()
        reloadCurrentTab()
    }

    /// Close the tab at the specified index.
    func closeTab(at index: Int) {
        guard tabs.indices.contains(index), tabs.count > 1 else { return }

        tabs.remove(at: index)

        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }

        rebuildTabBar()
        reloadCurrentTab()
    }

    /// Returns the URL of the currently active tab.
    func currentURL() -> URL {
        guard tabs.indices.contains(activeTabIndex) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return tabs[activeTabIndex].url
    }

    /// Sets the active/focused visual state of this pane.
    func setActive(_ active: Bool) {
        isActive = active
        activeIndicatorBar.isHidden = !active
    }

    /// Updates the icon style and reloads the file list and path bar.
    /// Only updates view controllers that have already been instantiated to avoid
    /// eagerly forcing lazy view controllers into existence.
    func setIconStyle(_ style: IconStyle) {
        iconStyle = style
        pathBarView.setIconStyle(style)
        fileListViewController.setIconStyle(style)
        if currentViewMode == .icon {
            iconGridViewController.setIconStyle(style)
        }
        if currentViewMode == .column {
            columnBrowserViewController.setIconStyle(style)
        }
    }

    /// Updates the show hidden files setting and reloads the file list.
    func setShowHiddenFiles(_ show: Bool) {
        showHiddenFiles = show
        fileListViewController.setShowHiddenFiles(show)
        if currentViewMode == .icon {
            iconGridViewController.setShowHiddenFiles(show)
        }
        if currentViewMode == .column {
            columnBrowserViewController.setShowHiddenFiles(show)
        }
    }

    /// Switches to the specified view mode, loading the current directory into the new view.
    func setViewMode(_ mode: ViewMode) {
        guard mode != currentViewMode else { return }

        // Remove the current view from the container
        removeActiveViewFromContainer()

        currentViewMode = mode
        suppressSelectionClear = true

        let url = currentURL()

        switch mode {
        case .list:
            if fileListViewController.parent == nil {
                addChild(fileListViewController)
                fileListViewController.delegate = self
            }
            fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
            embedViewInContainer(fileListViewController.view)
            fileListViewController.loadDirectory(at: url)

        case .icon:
            if iconGridViewController.parent == nil {
                addChild(iconGridViewController)
                iconGridViewController.delegate = self
            }
            iconGridViewController.view.translatesAutoresizingMaskIntoConstraints = false
            embedViewInContainer(iconGridViewController.view)
            iconGridViewController.loadDirectory(at: url)

        case .column:
            if columnBrowserViewController.parent == nil {
                addChild(columnBrowserViewController)
                columnBrowserViewController.delegate = self
            }
            columnBrowserViewController.view.translatesAutoresizingMaskIntoConstraints = false
            embedViewInContainer(columnBrowserViewController.view)
            columnBrowserViewController.loadDirectory(at: url)

        case .gallery:
            // Gallery falls back to list view for now
            if fileListViewController.parent == nil {
                addChild(fileListViewController)
                fileListViewController.delegate = self
            }
            fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
            embedViewInContainer(fileListViewController.view)
            fileListViewController.loadDirectory(at: url)
        }
    }

    // MARK: - View Container Helpers

    /// Embeds a view inside the content container, pinning all edges.
    private func embedViewInContainer(_ childView: NSView) {
        contentContainerView.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
            childView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
        ])
    }

    /// Removes the currently active view from the container.
    private func removeActiveViewFromContainer() {
        switch currentViewMode {
        case .list, .gallery:
            fileListViewController.view.removeFromSuperview()
        case .icon:
            iconGridViewController.view.removeFromSuperview()
        case .column:
            columnBrowserViewController.view.removeFromSuperview()
        }
    }

    // MARK: - Keyboard Navigation

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 36: // Return/Enter - open selected item
            let items = selectedItems()
            for item in items {
                if item.isDirectory {
                    navigateTo(url: item.url)
                } else {
                    NSWorkspace.shared.open(item.url)
                }
            }
        case 120 where flags.isEmpty: // F2 - rename
            if currentViewMode == .list || currentViewMode == .gallery {
                fileListViewController.renameSelection(nil)
            }
        case 49 where flags.isEmpty: // Space - play/pause or Quick Look
            if let handler = onSpacebarPressed, handler() {
                break
            }
            switch currentViewMode {
            case .list, .gallery:
                fileListViewController.toggleQuickLook()
            case .icon:
                iconGridViewController.toggleQuickLook()
            case .column:
                columnBrowserViewController.toggleQuickLook()
            }
        case 126 where flags.contains(.command): // Cmd+Up - parent directory
            goToParent()
        case 51: // Backspace/Delete - go back
            goBack()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Tab Bar

    private func rebuildTabBar() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Hide the tab bar when there's only one tab
        let singleTab = tabs.count <= 1
        tabBar.isHidden = singleTab
        tabBarHeightConstraint?.constant = singleTab ? 0 : Layout.tabBarHeight
        tabBar.layer?.backgroundColor = singleTab ? nil : NSColor.windowBackgroundColor.cgColor

        guard !singleTab else { return }

        for (index, tab) in tabs.enumerated() {
            let button = makeTabButton(title: tab.title, index: index, isSelected: index == activeTabIndex)
            tabBar.addArrangedSubview(button)
        }
    }

    private func makeTabButton(title: String, index: Int, isSelected: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
        container.layer?.cornerRadius = 4

        let button = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
        button.tag = index
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!,
            target: self,
            action: #selector(closeTabClicked(_:))
        )
        closeButton.tag = index
        closeButton.isBordered = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = tabs.count <= 1
        container.addSubview(closeButton)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            container.heightAnchor.constraint(equalToConstant: Layout.tabBarHeight - 4),
        ])

        return container
    }

    @objc private func tabClicked(_ sender: NSButton) {
        let index = sender.tag
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
        rebuildTabBar()
        reloadCurrentTab()
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        closeTab(at: sender.tag)
    }

    // MARK: - Reload

    private func reloadCurrentTab() {
        guard tabs.indices.contains(activeTabIndex) else { return }
        let url = tabs[activeTabIndex].url
        pathBarView.update(with: url)

        // Reload whichever view is currently active
        switch currentViewMode {
        case .list, .gallery:
            fileListViewController.loadDirectory(at: url)
        case .icon:
            iconGridViewController.loadDirectory(at: url)
        case .column:
            columnBrowserViewController.loadDirectory(at: url)
        }

        // Selection is cleared on directory reload — notify delegate
        // (but not during a view mode switch, to avoid clearing the preview)
        if suppressSelectionClear {
            suppressSelectionClear = false
        } else {
            delegate?.browserPane(self, didSelectItems: [])
        }
        // Directory monitoring starts in fileListViewDidFinishLoading once items are loaded.
    }

    private func updateStatusBar(itemCount: Int, selectedCount: Int) {
        if selectedCount > 0 {
            statusBar.stringValue = "\(itemCount) items, \(selectedCount) selected"
        } else {
            statusBar.stringValue = "\(itemCount) items"
        }
    }
}

// MARK: - PathBarDelegate

extension BrowserPaneViewController: PathBarDelegate {
    func pathBar(_ pathBar: PathBarView, didNavigateTo url: URL) {
        navigateTo(url: url)
    }

    func pathBar(_ pathBar: PathBarView, didEditPath url: URL) {
        navigateTo(url: url)
    }
}

// MARK: - FileListViewDelegate

extension BrowserPaneViewController: FileListViewDelegate {
    func fileListView(_ controller: FileListViewController, didSelectItems items: [FileItem]) {
        updateStatusBar(itemCount: controller.itemCount, selectedCount: items.count)
        delegate?.browserPane(self, didSelectItems: items)
    }

    func fileListView(_ controller: FileListViewController, didOpenItem item: FileItem) {
        if item.isDirectory {
            navigateTo(url: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func fileListView(_ controller: FileListViewController, didRequestContextMenu items: [FileItem]) {
        // Context menu is built and displayed by FileListViewController itself
    }

    func fileListViewDidFinishLoading(_ controller: FileListViewController, itemCount: Int) {
        updateStatusBar(itemCount: itemCount, selectedCount: 0)

        // Update the directory monitor's known paths now that loading is complete.
        if let url = controller.currentDirectoryURL {
            let knownPaths = Set(controller.currentItems.map { $0.url.path })
            directoryMonitor.startMonitoring(url: url, knownPaths: knownPaths)
        }
    }
}

// MARK: - DirectoryMonitorDelegate

extension BrowserPaneViewController: DirectoryMonitorDelegate {
    func directoryMonitor(_ monitor: DirectoryMonitor, didObserveChanges events: [DirectoryChangeEvent]) {
        // Only apply incremental changes to the list view; other views do a full reload.
        if currentViewMode == .list || currentViewMode == .gallery {
            fileListViewController.applyChanges(events)
            updateStatusBar(itemCount: fileListViewController.itemCount, selectedCount: 0)
        } else {
            reloadCurrentTab()
        }
    }
}

// MARK: - IconGridViewDelegate

extension BrowserPaneViewController: IconGridViewDelegate {
    func iconGridView(_ controller: IconGridViewController, didSelectItems items: [FileItem]) {
        updateStatusBar(itemCount: controller.itemCount, selectedCount: items.count)
        delegate?.browserPane(self, didSelectItems: items)
    }

    func iconGridView(_ controller: IconGridViewController, didOpenItem item: FileItem) {
        if item.isDirectory {
            navigateTo(url: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func iconGridView(_ controller: IconGridViewController, didRequestContextMenu items: [FileItem]) {
        // Context menu is built and displayed by IconGridViewController itself
    }

    func iconGridViewDidFinishLoading(_ controller: IconGridViewController, itemCount: Int) {
        updateStatusBar(itemCount: itemCount, selectedCount: 0)

        if let url = controller.currentDirectoryURL {
            let knownPaths = Set(controller.currentItems.map { $0.url.path })
            directoryMonitor.startMonitoring(url: url, knownPaths: knownPaths)
        }
    }
}

// MARK: - ColumnBrowserViewDelegate

extension BrowserPaneViewController: ColumnBrowserViewDelegate {
    func columnBrowserView(
        _ controller: ColumnBrowserViewController, didSelectItems items: [FileItem]
    ) {
        updateStatusBar(itemCount: controller.itemCount, selectedCount: items.count)
        delegate?.browserPane(self, didSelectItems: items)
    }

    func columnBrowserView(
        _ controller: ColumnBrowserViewController, didOpenItem item: FileItem
    ) {
        if item.isDirectory {
            navigateTo(url: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func columnBrowserView(
        _ controller: ColumnBrowserViewController, didRequestContextMenu items: [FileItem]
    ) {
        // Context menu is built and displayed by ColumnBrowserViewController itself
    }

    func columnBrowserViewDidFinishLoading(
        _ controller: ColumnBrowserViewController, itemCount: Int
    ) {
        updateStatusBar(itemCount: itemCount, selectedCount: 0)

        if let url = controller.currentDirectoryURL {
            let knownPaths = Set(controller.currentItems.map { $0.url.path })
            directoryMonitor.startMonitoring(url: url, knownPaths: knownPaths)
        }
    }
}
