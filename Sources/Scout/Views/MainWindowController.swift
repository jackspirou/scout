import Cocoa

// MARK: - Titleless Window

/// NSWindow subclass that suppresses all automatic title updates.
/// macOS sets the window title from child view controllers and content;
/// this prevents any title or proxy icon from appearing in the title bar.
private final class TitlelessWindow: NSWindow {
    override var title: String {
        get { "" }
        set { /* ignored */ }
    }

    override var representedURL: URL? {
        get { nil }
        set { /* ignored */ }
    }
}

// MARK: - Toolbar Item Identifiers

private extension NSToolbarItem.Identifier {
    static let toggleSidebar = NSToolbarItem.Identifier("com.scout.toolbar.sidebar")
    static let backButton = NSToolbarItem.Identifier("com.scout.toolbar.back")
    static let forwardButton = NSToolbarItem.Identifier("com.scout.toolbar.forward")

    static let viewMode = NSToolbarItem.Identifier("com.scout.toolbar.viewMode")
    static let searchField = NSToolbarItem.Identifier("com.scout.toolbar.search")
    static let toggleDualPane = NSToolbarItem.Identifier("com.scout.toolbar.dualPane")
    static let togglePreview = NSToolbarItem.Identifier("com.scout.toolbar.preview")
}

// MARK: - MainWindowController

final class MainWindowController: NSWindowController {
    // MARK: - Properties

    private(set) var iconStyle: IconStyle = .system
    private(set) var showHiddenFiles: Bool = true

    private(set) var isDualPane: Bool = false {
        didSet {
            guard !suppressDualPaneDidChange else { return }
            dualPaneDidChange()
        }
    }

    /// When true, setting `isDualPane` skips `dualPaneDidChange` to avoid
    /// double-toggling the container during session restore.
    private var suppressDualPaneDidChange: Bool = false

    private(set) var showPreview: Bool = false {
        didSet { previewDidChange() }
    }

    private(set) var showSidebar: Bool = true {
        didSet { sidebarDidChange() }
    }

    /// Whether the user has explicitly closed the preview. Prevents auto-open after dismissal.
    private var userDismissedPreview: Bool = false

    private let contentController = NSViewController()
    private let splitView = NSSplitView()
    private let browserContainer = BrowserContainerViewController()
    private let previewViewController = PreviewViewController()
    private let sidebarViewController = SidebarViewController()
    private var sidebarView: NSView!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var searchField: NSSearchField?
    private var viewModeSegmentedControl: NSSegmentedControl?
    private var searchDebounceTimer: Timer?

    /// The clipboard manager used by the browser container.
    var clipboardManager: ClipboardManager {
        browserContainer.clipboardManager
    }

    private enum SidebarLayout {
        static let defaultWidth: CGFloat = 180
    }

    // MARK: - Initialization

    convenience init() {
        let window = Self.makeWindow()
        self.init(window: window)
        self.iconStyle = PersistenceService.shared.loadIconStyle()
        self.showHiddenFiles = PersistenceService.shared.loadShowHiddenFiles()
        browserContainer.setIconStyle(iconStyle)
        browserContainer.setShowHiddenFiles(showHiddenFiles)
        previewViewController.onNavigate = { [weak self] (url: URL) in
            self?.searchField?.stringValue = ""
            self?.browserContainer.activePaneController().navigateTo(url: url)
        }
        browserContainer.onSpacebarPressed = { [weak self] in
            guard let self, self.showPreview, self.previewViewController.handlesSpacebar else {
                return false
            }
            self.previewViewController.togglePlayback()
            return true
        }
        configureContentSplitView()
        configureToolbar()
    }

    // MARK: - Window Factory

    private static func makeWindow() -> NSWindow {
        let window = TitlelessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.minSize = NSSize(width: 1040, height: 600)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.center()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        return window
    }

    // MARK: - Content Configuration

    private func configureContentSplitView() {
        // Use a plain NSViewController + NSSplitView (NOT NSSplitViewController)
        // to avoid macOS automatically injecting a navigation title into the toolbar.
        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentController.view = containerView

        // --- Sidebar (sibling view, NOT a split pane) ---
        sidebarView = NSView()
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(sidebarView)

        contentController.addChild(sidebarViewController)
        sidebarViewController.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarViewController.view)

        NSLayoutConstraint.activate([
            sidebarViewController.view.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            sidebarViewController.view.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
            sidebarViewController.view.leadingAnchor.constraint(
                equalTo: sidebarView.leadingAnchor),
            sidebarViewController.view.trailingAnchor.constraint(
                equalTo: sidebarView.trailingAnchor),
        ])

        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: SidebarLayout.defaultWidth
        )

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: containerView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            sidebarWidthConstraint,
        ])

        // Wire sidebar navigation callback
        sidebarViewController.onNavigate = { [weak self] url in
            self?.searchField?.stringValue = ""
            self?.browserContainer.activePaneController().navigateTo(url: url)
        }

        // Wire sidebar tag search callback
        sidebarViewController.onSearchTag = { [weak self] tagName in
            self?.searchForTag(tagName)
        }

        // --- Split view (browser + preview, unchanged 2-pane layout) ---
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: containerView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            splitView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])

        // Add browser container as the primary pane
        browserContainer.delegate = self
        contentController.addChild(browserContainer)
        browserContainer.view.translatesAutoresizingMaskIntoConstraints = false
        splitView.addSubview(browserContainer.view)

        // Add preview pane (collapsed by default — divider pushed to far right)
        contentController.addChild(previewViewController)
        splitView.addSubview(previewViewController.view)

        window?.contentViewController = contentController

        // Collapse preview pane by pushing divider to the far right.
        // Defer so the split view has its final layout size.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitView.setPosition(self.splitView.bounds.width, ofDividerAt: 0)
        }
    }

    // MARK: - Toolbar

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "com.scout.mainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    // MARK: - Public API

    func toggleDualPane() {
        isDualPane.toggle()
    }

    func togglePreview() {
        if showPreview {
            userDismissedPreview = true
        } else {
            userDismissedPreview = false
        }
        showPreview.toggle()
    }

    func openNewTab() {
        browserContainer.activePaneController().addTab(url: FileManager.default.homeDirectoryForCurrentUser)
    }

    func setIconStyle(_ style: IconStyle) {
        iconStyle = style
        PersistenceService.shared.saveIconStyle(style)
        browserContainer.setIconStyle(style)
    }

    func toggleShowHiddenFiles() {
        showHiddenFiles.toggle()
        PersistenceService.shared.saveShowHiddenFiles(showHiddenFiles)
        browserContainer.setShowHiddenFiles(showHiddenFiles)
    }

    /// The number of tabs in the active pane (for menu validation).
    var activePaneTabCount: Int {
        browserContainer.activePaneController().tabCount
    }

    func closeCurrentTab() {
        let pane = browserContainer.activePaneController()
        guard pane.tabCount > 1 else { return }
        pane.closeTab(at: pane.activeTabIndex)
    }

    /// Navigates the active browser pane to the given URL.
    func navigateToURL(_ url: URL) {
        searchField?.stringValue = ""
        browserContainer.activePaneController().navigateTo(url: url)
    }

    /// Returns the current URL of the active browser pane.
    func currentURL() -> URL {
        browserContainer.activePaneController().currentURL()
    }

    /// Returns the currently selected file items in the active browser pane.
    func selectedItems() -> [FileItem] {
        browserContainer.activePaneController().selectedItems()
    }

    /// Focuses the toolbar search field.
    func focusSearchField() {
        guard let searchField else { return }
        window?.makeFirstResponder(searchField)
    }

    /// Toggles sidebar visibility.
    func toggleSidebar() {
        showSidebar.toggle()
    }

    // MARK: - Session State

    /// Captures the current window state for session persistence.
    func captureWindowState() -> WindowState {
        let frame = window?.frame ?? .zero
        let windowFrame = WindowFrame(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.size.width),
            height: Double(frame.size.height)
        )

        let containerState = browserContainer.captureContainerState()

        let leftTab = TabState(
            paneState: PaneState(
                path: containerState.leftURL,
                viewSettings: .default,
                scrollPosition: 0,
                selectedItems: []
            ),
            title: containerState.leftURL.lastPathComponent,
            isPinned: false
        )

        let rightTab = TabState(
            paneState: PaneState(
                path: containerState.rightURL,
                viewSettings: .default,
                scrollPosition: 0,
                selectedItems: []
            ),
            title: containerState.rightURL.lastPathComponent,
            isPinned: false
        )

        return WindowState(
            leftTabs: [leftTab],
            rightTabs: [rightTab],
            activeLeftTab: 0,
            activeRightTab: 0,
            isDualPane: containerState.isDualPane,
            showPreview: showPreview,
            windowFrame: windowFrame,
            sidebarWidth: Double(sidebarWidthConstraint?.constant ?? CGFloat(SidebarLayout.defaultWidth))
        )
    }

    /// Restores window state from a previous session.
    func restoreWindowState(_ state: WindowState) {
        // Restore window frame
        if let frame = state.windowFrame {
            let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            window?.setFrame(rect, display: true)
        }

        // Restore sidebar width
        sidebarWidthConstraint?.constant = CGFloat(state.sidebarWidth)

        // Restore preview state
        if state.showPreview != showPreview {
            togglePreview()
        }

        // Navigate to saved pane paths and restore dual pane state via the container.
        // No fileExists check — navigateTo handles missing directories gracefully
        // by showing an empty listing, avoiding a TOCTOU race.
        let leftURL = state.leftTabs.first?.paneState.path
            ?? FileManager.default.homeDirectoryForCurrentUser
        let rightURL = state.rightTabs.first?.paneState.path
            ?? FileManager.default.homeDirectoryForCurrentUser

        browserContainer.restoreContainerState(
            leftURL: leftURL,
            rightURL: rightURL,
            isDualPane: state.isDualPane
        )

        // Sync local isDualPane from the container's authoritative state
        // without triggering dualPaneDidChange (which would double-toggle).
        suppressDualPaneDidChange = true
        isDualPane = browserContainer.isDualPaneActive
        suppressDualPaneDidChange = false
    }

    // MARK: - State Change Handlers

    private func sidebarDidChange() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            sidebarWidthConstraint.constant = showSidebar ? SidebarLayout.defaultWidth : 0
            contentController.view.layoutSubtreeIfNeeded()
        }
    }

    private func dualPaneDidChange() {
        browserContainer.toggleDualPane()
        window?.toolbar?.validateVisibleItems()
        if showPreview {
            updatePreviewForCurrentSelection()
        }
    }

    private func previewDidChange() {
        if !showPreview {
            previewViewController.clearPreview()
        }

        let totalWidth = splitView.bounds.width
        guard totalWidth > 0 else { return }

        if showPreview {
            previewViewController.view.isHidden = false
            let previewWidth = max(totalWidth * 0.35, 250)
            splitView.setPosition(totalWidth - previewWidth, ofDividerAt: 0)
            updatePreviewForCurrentSelection()
        } else {
            previewViewController.view.isHidden = true
            splitView.setPosition(totalWidth, ofDividerAt: 0)
        }
    }

    private func updatePreviewForCurrentSelection() {
        let selectedItems = browserContainer.activePaneController().selectedItems()
        if selectedItems.count == 1 {
            previewViewController.previewItem(selectedItems.first)
        } else {
            previewViewController.clearPreview()
        }
    }

    // MARK: - Tag Search

    /// Observation token for the tag search metadata query notification.
    private static var tagSearchObserver: NSObjectProtocol?

    /// Strong reference to the in-flight metadata query so it is not deallocated before results arrive.
    private var tagSearchQuery: NSMetadataQuery?

    /// Searches for files with the given Finder tag and displays results in the active browser pane.
    private func searchForTag(_ tagName: String) {
        // Stop any existing query before starting a new one.
        tagSearchQuery?.stop()
        tagSearchQuery = nil

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemUserTags CONTAINS[c] %@", tagName)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]

        // Remove any previous observer to avoid duplicates.
        if let previousObserver = Self.tagSearchObserver {
            NotificationCenter.default.removeObserver(previousObserver)
            Self.tagSearchObserver = nil
        }

        Self.tagSearchObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self, weak query] _ in
            guard let self, let query else { return }
            query.stop()
            self.tagSearchQuery = nil

            // Remove the observer now that the query has finished.
            if let observer = Self.tagSearchObserver {
                NotificationCenter.default.removeObserver(observer)
                Self.tagSearchObserver = nil
            }

            var items: [FileItem] = []
            for i in 0..<query.resultCount {
                if let result = query.result(at: i) as? NSMetadataItem,
                   let path = result.value(forAttribute: NSMetadataItemPathKey) as? String {
                    let url = URL(fileURLWithPath: path)
                    if let fileItem = FileItem.create(from: url, iconStyle: self.iconStyle) {
                        items.append(fileItem)
                    }
                }
            }

            self.browserContainer.activePaneController().displaySearchResults(
                items,
                title: "Tag: \(tagName)"
            )
        }

        self.tagSearchQuery = query
        query.start()
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .backButton,
            .forwardButton,
            .flexibleSpace,
            .viewMode,
            .searchField,
            .toggleDualPane,
            .togglePreview,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            return makeSidebarItem(identifier: itemIdentifier)
        case .backButton:
            return makeBackItem(identifier: itemIdentifier)
        case .forwardButton:
            return makeForwardItem(identifier: itemIdentifier)
        case .viewMode:
            return makeViewModeItem(identifier: itemIdentifier)
        case .searchField:
            return makeSearchItem(identifier: itemIdentifier)
        case .toggleDualPane:
            return makeDualPaneItem(identifier: itemIdentifier)
        case .togglePreview:
            return makePreviewItem(identifier: itemIdentifier)
        default:
            return nil
        }
    }

    // MARK: - Toolbar Item Factories

    private func makeSidebarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Sidebar"
        item.paletteLabel = "Toggle Sidebar"
        item.toolTip = "Toggle Sidebar"
        item.image = NSImage(
            systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
        item.target = self
        item.action = #selector(toggleSidebarAction(_:))
        return item
    }

    private func makeBackItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Back"
        item.paletteLabel = "Back"
        item.toolTip = "Go Back"
        item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        item.target = self
        item.action = #selector(backAction(_:))
        return item
    }

    private func makeForwardItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Forward"
        item.paletteLabel = "Forward"
        item.toolTip = "Go Forward"
        item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        item.target = self
        item.action = #selector(forwardAction(_:))
        return item
    }

    private func makeViewModeItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "View"
        item.paletteLabel = "View Mode"

        let segmented = NSSegmentedControl(images: [
            NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
            NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid")!,
            NSImage(systemSymbolName: "rectangle.grid.1x2", accessibilityDescription: "Column")!,
        ], trackingMode: .selectOne, target: self, action: #selector(viewModeChanged(_:)))
        segmented.selectedSegment = 0
        segmented.segmentStyle = .automatic

        viewModeSegmentedControl = segmented
        item.view = segmented
        return item
    }

    private func makeSearchItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let searchItem = NSSearchToolbarItem(itemIdentifier: identifier)
        searchItem.searchField.placeholderString = "Search"
        searchItem.searchField.delegate = self
        searchField = searchItem.searchField
        return searchItem
    }

    private func makeDualPaneItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Dual Pane"
        item.paletteLabel = "Toggle Dual Pane"
        item.toolTip = "Toggle Dual Pane"
        item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Dual Pane")
        item.target = self
        item.action = #selector(toggleDualPaneAction(_:))
        return item
    }

    private func makePreviewItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Preview"
        item.paletteLabel = "Toggle Preview"
        item.toolTip = "Toggle Preview Panel"
        item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Preview")
        item.target = self
        item.action = #selector(togglePreviewAction(_:))
        return item
    }

    // MARK: - Toolbar Actions

    @objc private func backAction(_ sender: Any?) {
        browserContainer.activePaneController().goBack()
    }

    @objc private func forwardAction(_ sender: Any?) {
        browserContainer.activePaneController().goForward()
    }

    @objc private func toggleSidebarAction(_ sender: Any?) {
        toggleSidebar()
    }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        let modes: [ViewMode] = [.list, .icon, .column]
        let index = sender.selectedSegment
        guard index >= 0, index < modes.count else { return }
        browserContainer.activePaneController().setViewMode(modes[index])
    }

    @objc private func toggleDualPaneAction(_ sender: Any?) {
        toggleDualPane()
    }

    @objc private func togglePreviewAction(_ sender: Any?) {
        togglePreview()
    }
}

// MARK: - NSSplitViewDelegate

extension MainWindowController: NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        300 // minimum browser pane width
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        showPreview ? splitView.bounds.width - 250 : splitView.bounds.width
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === previewViewController.view
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        !showPreview
    }
}

// MARK: - NSSearchFieldDelegate

extension MainWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        let query = field.stringValue
        searchDebounceTimer?.invalidate()
        searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.browserContainer.setFilterQuery(query)
        }
    }
}

// MARK: - BrowserContainerDelegate

extension MainWindowController: BrowserContainerDelegate {
    func browserContainer(_ container: BrowserContainerViewController, didSwitchToViewMode mode: ViewMode) {
        let modes: [ViewMode] = [.list, .icon, .column]
        if let index = modes.firstIndex(of: mode) {
            viewModeSegmentedControl?.selectedSegment = index
        }
    }

    func browserContainer(_ container: BrowserContainerViewController, didSelectItems items: [FileItem]) {
        if items.count == 1 {
            let item = items[0]

            // Auto-open preview on first text/image file selection (unless user dismissed it).
            // previewDidChange() already calls updatePreviewForCurrentSelection(), so skip
            // the explicit previewItem call when auto-opening to avoid loading twice.
            if !showPreview, !userDismissedPreview, !item.isDirectory, (item.isText || item.isImage || item.isPDF || item.isVideo || item.isAudio) {
                showPreview = true
                return
            }

            if showPreview {
                previewViewController.previewItem(item)
            }
        } else if showPreview {
            previewViewController.clearPreview()
        }
    }
}
