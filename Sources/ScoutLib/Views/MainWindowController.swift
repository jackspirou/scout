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
    static let settings = NSToolbarItem.Identifier("com.scout.toolbar.settings")
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

    // Search state
    private let searchService = SearchService()
    private let searchfsService = SearchfsService()
    private let scoutDropService = ScoutDropService()
    private var searchTask: Task<Void, Never>?
    private var scoutDropPeerTask: Task<Void, Never>?
    private var scoutDropOfferTask: Task<Void, Never>?
    private var scoutDropVerificationTask: Task<Void, Never>?
    private var isSearchActive = false
    private var preSearchURL: URL?
    private var activeFilters: [SearchFilter] = []
    private var activeDisplayTokens: [SearchFilterToken.DisplayToken] = []

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
        iconStyle = PersistenceService.shared.loadIconStyle()
        showHiddenFiles = PersistenceService.shared.loadShowHiddenFiles()
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
                equalTo: sidebarView.leadingAnchor
            ),
            sidebarViewController.view.trailingAnchor.constraint(
                equalTo: sidebarView.trailingAnchor
            ),
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

        // Wire sidebar Recents callback
        sidebarViewController.onShowRecents = { [weak self] in
            self?.showRecents()
        }

        // Wire sidebar AirDrop callback
        sidebarViewController.onAirDrop = { [weak self] in
            self?.showAirDrop()
        }

        // Wire sidebar ScoutDrop callback (drag files onto a nearby peer)
        sidebarViewController.onScoutDrop = { [weak self] urls, peer in
            guard let self else { return }
            Task {
                do {
                    let isTrusted = peer.deviceID.map {
                        PersistenceService.shared.isScoutDropPeerTrusted(deviceID: $0)
                    } ?? false

                    try await self.scoutDropService.sendFiles(urls, to: peer)

                    // Mark as trusted after successful transfer (TOFU).
                    if !isTrusted, let deviceID = peer.deviceID {
                        PersistenceService.shared.saveScoutDropTrustedPeer(
                            deviceID: deviceID,
                            name: peer.name
                        )
                    }
                } catch {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "ScoutDrop Failed"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            }
        }

        // Wire sidebar workspace callbacks
        sidebarViewController.onLoadWorkspace = { [weak self] workspace in
            var updated = workspace
            updated.lastUsedAt = Date()
            Task {
                await PersistenceService.shared.saveWorkspace(updated)
            }
            self?.restoreWindowState(workspace.windowState, restoreFrame: false)
            self?.sidebarViewController.setActiveWorkspace(workspace)
        }

        sidebarViewController.onSaveWorkspace = { [weak self] in
            NSApp.sendAction(NSSelectorFromString("handleSaveWorkspace:"), to: nil, from: self)
        }

        // Start ScoutDrop advertising and browsing
        startScoutDrop()

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

    // MARK: - Spotlight Search

    /// Executes a Spotlight search with the current query and scope.
    private func executeSearch(query: String) {
        guard !query.isEmpty else {
            exitSearch()
            return
        }

        // Parse filter tokens (kind:pdf, size:>10mb, etc.) from the query
        let parsed = SearchFilterToken.parse(query)
        activeFilters = parsed.filters
        activeDisplayTokens = parsed.displayTokens
        let textQuery = parsed.textQuery
        updateTokenBar()

        // If we extracted all tokens and no text remains, still need something to search
        let effectiveQuery = textQuery.isEmpty && !activeFilters.isEmpty ? "*" : textQuery
        guard !effectiveQuery.isEmpty else {
            exitSearch()
            return
        }

        // Always capture the current directory for scope and restore.
        // currentURL() returns the tab's URL which persists through searches.
        preSearchURL = browserContainer.activePaneController().currentURL()
        isSearchActive = true

        // Clear the local filter so search results aren't further filtered
        // by the text in the search field (Spotlight already handles the query).
        browserContainer.setFilterQuery("")

        searchTask?.cancel()

        // Always search from the current folder
        let currentURL = preSearchURL ?? browserContainer.activePaneController().currentURL()
        let scope: SearchScope = .subfolder(currentURL)

        browserContainer.activePaneController().setSearchInProgress(true)

        // Build display title: "FolderName Search: text" with filter labels
        let folderName = browserContainer.activePaneController().currentURL().lastPathComponent
        let filterLabels = activeDisplayTokens.map(\.label)
        var searchSuffix = ""
        if !textQuery.isEmpty {
            searchSuffix = " \(textQuery)"
        }
        let displayTitle = "\(folderName) Search:\(searchSuffix)"

        // Immediately clear old results so the user doesn't see stale data
        browserContainer.activePaneController().displaySearchResults(
            [], title: displayTitle, filterLabels: filterLabels
        )

        let filters = activeFilters
        searchTask = Task { [weak self] in
            guard let self else { return }

            // Three search backends, each suited to a different scope:
            //
            // 1. FileManager.enumerator — folder-scoped searches. Walks the directory tree
            //    directly, catching everything Spotlight misses (unindexed directories, new files).
            //
            // 2. Spotlight (NSMetadataQuery) — runs for both scopes. Provides user-relevant,
            //    content-aware results from indexed volumes.
            //
            // 3. searchfs() — external/non-Spotlight-indexed volumes only. Reads the APFS/HFS+
            //    catalog B-tree directly at kernel level. Fills the gap where Spotlight has no
            //    coverage (e.g., USB drives, external APFS volumes).
            //
            // Results from all backends are deduplicated by URL.
            var seenURLs = Set<URL>()
            var allItems: [FileItem] = []
            let title = displayTitle

            let folderURL: URL?
            switch scope {
            case let .currentFolder(url), let .subfolder(url):
                folderURL = url
            case .fullDisk:
                folderURL = nil
            }

            // Phase 1: Folder-scoped — FileManager.enumerator for complete directory results.
            if let folderURL {
                var fsItems: [FileItem]
                if textQuery.isEmpty && !filters.isEmpty {
                    // Filter-only search: scan all files, apply filters (no glob matching)
                    fsItems = await self.filesystemSearchAll(in: folderURL, filters: filters)
                } else {
                    fsItems = await self.filesystemSearch(query: effectiveQuery, in: folderURL)
                    if !filters.isEmpty {
                        fsItems = fsItems.filter { item in filters.allSatisfy { $0.matches(item) } }
                    }
                }
                if !Task.isCancelled {
                    for item in fsItems {
                        if seenURLs.insert(item.url).inserted {
                            allItems.append(item)
                        }
                    }
                    // Always display results (even if empty) so old listing is replaced
                    let snapshot = allItems
                    await MainActor.run {
                        self.browserContainer.activePaneController().displaySearchResults(
                            snapshot, title: title
                        )
                    }
                }
            }

            // Phase 2: Spotlight — runs for both scopes. Provides user-relevant results
            // from indexed volumes. For "This Mac", this is the primary search backend.
            let stream = await self.searchService.search(
                query: effectiveQuery, scope: scope, filters: filters
            )
            for await batch in stream {
                guard !Task.isCancelled else { return }
                for item in batch {
                    if seenURLs.insert(item.url).inserted {
                        if filters.isEmpty || filters.allSatisfy({ $0.matches(item) }) {
                            allItems.append(item)
                        }
                    }
                }
                let snapshot = allItems
                await MainActor.run {
                    self.browserContainer.activePaneController().displaySearchResults(
                        snapshot, title: title
                    )
                }
            }

            // Phase 3: searchfs() — non-Spotlight-indexed volumes only (e.g., external
            // USB/Thunderbolt APFS/HFS+ drives). Fills the gap where Spotlight has no
            // coverage. Skipped for folder-scoped searches since the folder is on
            // an indexed volume (handled by FileManager.enumerator above).
            if folderURL == nil {
                let searchfsStream = await self.searchfsService.searchNonIndexedVolumes(
                    query: effectiveQuery, maxResults: 10000
                )
                for await batch in searchfsStream {
                    guard !Task.isCancelled else { return }
                    for item in batch {
                        if seenURLs.insert(item.url).inserted {
                            if filters.isEmpty || filters.allSatisfy({ $0.matches(item) }) {
                                allItems.append(item)
                            }
                        }
                    }
                    let snapshot = allItems
                    await MainActor.run {
                        self.browserContainer.activePaneController().displaySearchResults(
                            snapshot, title: title
                        )
                    }
                }
            }

            // Search complete — stop the spinner. exitSearch() also stops it for cancellations.
            await MainActor.run { [weak self] in
                self?.browserContainer.activePaneController().setSearchInProgress(false)
            }
        }
    }

    /// Recursively searches the filesystem for items matching the query.
    ///
    /// This exists because Spotlight's index (NSMetadataQuery) has incomplete coverage.
    /// Some filesystem entries — particularly directories, recently created files, and
    /// items in paths Spotlight deprioritizes — have null metadata (verified via `mdls`)
    /// and are invisible to Spotlight queries. By walking the directory tree directly
    /// with FileManager.enumerator, we guarantee that all matching items within the
    /// scoped folder appear in search results regardless of Spotlight's index state.
    ///
    /// The query supports the same glob patterns as the Spotlight search:
    /// - `*` matches zero or more characters
    /// - `?` matches exactly one character
    /// - Plain text (no wildcards) does a case-insensitive substring match
    ///
    /// Results are capped at 1000 items to avoid blocking on very large directory trees.
    private func filesystemSearch(query: String, in directory: URL) async -> [FileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // Build a regex from the query using the shared GlobPattern utility.
        // Supports glob wildcards (*, ?) and plain text substring matching.
        guard let regex = GlobPattern.buildRegex(from: trimmed) else {
            return []
        }

        // Run on a detached task to avoid blocking the main actor.
        // Use a synchronous closure for FileManager.enumerator iteration to avoid
        // the Swift 6 warning about makeIterator being unavailable in async contexts.
        return await Task.detached {
            var items: [FileItem] = []
            let fm = FileManager.default

            // Pass 1: Scan immediate children first so top-level matches
            // (e.g. "Music" in ~/) are always found before the cap is hit.
            if let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
                options: []
            ) {
                for url in contents {
                    if Task.isCancelled { break }
                    let name = url.lastPathComponent
                    if GlobPattern.matches(name, regex: regex) {
                        if let item = FileItem.create(from: url, iconStyle: .system) {
                            items.append(item)
                        }
                    }
                }
            }

            // Pass 2: Recurse into subdirectories for deeper matches.
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
                options: [.skipsPackageDescendants]
            ) else { return items }

            let topLevelURLs = Set(items.map(\.url))
            while let obj = enumerator.nextObject() {
                if Task.isCancelled { break }
                guard let url = obj as? URL else { continue }
                // Skip items already found in pass 1
                if topLevelURLs.contains(url) { continue }
                let name = url.lastPathComponent
                if GlobPattern.matches(name, regex: regex) {
                    if let item = FileItem.create(from: url, iconStyle: .system) {
                        items.append(item)
                    }
                }
                // Cap results to avoid hanging on huge directory trees.
                if items.count >= 1000 { break }
            }
            return items
        }.value
    }

    /// Scans all files in a directory and returns only those matching the given filters.
    /// Used for filter-only queries (e.g. `kind:pdf` with no text query) where glob matching
    /// is not needed — we just need to iterate files and apply structured filters.
    private func filesystemSearchAll(in directory: URL, filters: [SearchFilter]) async -> [FileItem] {
        return await Task.detached {
            var items: [FileItem] = []
            let fm = FileManager.default
            let resourceKeys: [URLResourceKey] = [.contentTypeKey, .fileSizeKey, .contentModificationDateKey, .tagNamesKey, .isDirectoryKey]

            // Pass 1: Immediate children first
            if let contents = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: resourceKeys, options: []
            ) {
                for url in contents {
                    if Task.isCancelled { break }
                    guard let item = FileItem.create(from: url, iconStyle: .system) else { continue }
                    if filters.allSatisfy({ $0.matches(item) }) {
                        items.append(item)
                    }
                }
            }

            // Pass 2: Recurse for deeper matches
            guard let enumerator = fm.enumerator(
                at: directory, includingPropertiesForKeys: resourceKeys,
                options: [.skipsPackageDescendants]
            ) else { return items }

            let topLevelURLs = Set(items.map(\.url))
            while let obj = enumerator.nextObject() {
                if Task.isCancelled { break }
                guard let url = obj as? URL else { continue }
                if topLevelURLs.contains(url) { continue }
                guard let item = FileItem.create(from: url, iconStyle: .system) else { continue }
                if filters.allSatisfy({ $0.matches(item) }) {
                    items.append(item)
                }
                if items.count >= 1000 { break }
            }
            return items
        }.value
    }

    /// Exits search mode and restores the original directory.
    private func exitSearch() {
        searchTask?.cancel()
        searchTask = nil
        Task { await searchService.cancelActiveSearch() }
        Task { await searchfsService.cancelActiveSearch() }
        browserContainer.activePaneController().setSearchInProgress(false)

        if isSearchActive, let url = preSearchURL {
            browserContainer.activePaneController().navigateTo(url: url)
        }
        isSearchActive = false
        preSearchURL = nil
        activeFilters = []
        activeDisplayTokens = []
        browserContainer.setFilterQuery("")
    }

    /// No-op — tokens are now shown in the tab title, not a separate bar.
    private func updateTokenBar() {}

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

        let state = browserContainer.captureFullContainerState()

        return WindowState(
            leftTabs: state.leftTabs,
            rightTabs: state.rightTabs,
            activeLeftTab: state.activeLeftTab,
            activeRightTab: state.activeRightTab,
            isDualPane: state.isDualPane,
            showPreview: showPreview,
            windowFrame: windowFrame,
            sidebarWidth: Double(sidebarWidthConstraint?.constant ?? CGFloat(SidebarLayout.defaultWidth)),
            showSidebar: showSidebar
        )
    }

    /// Restores window state from a previous session or workspace.
    /// When `restoreFrame` is true (default, used for session restore on launch),
    /// the window position and size are restored. When false (used for workspace
    /// switching), only the content is restored in the current window.
    func restoreWindowState(_ state: WindowState, restoreFrame: Bool = true) {
        // Restore window frame only on session restore, not workspace switch
        if restoreFrame, let frame = state.windowFrame {
            let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            window?.setFrame(rect, display: true)
        }

        // Restore sidebar visibility first (toggleSidebar sets width to default),
        // then override with the saved width.
        if state.showSidebar != showSidebar {
            toggleSidebar()
        }
        sidebarWidthConstraint?.constant = CGFloat(state.sidebarWidth)

        // Restore preview state
        if state.showPreview != showPreview {
            togglePreview()
        }

        // Restore all tabs and dual pane state via the container
        browserContainer.restoreFullContainerState(
            leftTabs: state.leftTabs,
            rightTabs: state.rightTabs,
            activeLeftTab: state.activeLeftTab,
            activeRightTab: state.activeRightTab,
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
            splitView.adjustSubviews()
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

    // MARK: - AirDrop

    private func showAirDrop() {
        let selectedItems = browserContainer.activePaneController().selectedItems()
        let urls = selectedItems.map(\.url)

        if !urls.isEmpty,
           let service = NSSharingService(named: .sendViaAirDrop),
           service.canPerform(withItems: urls)
        {
            // Files selected — show the system AirDrop device picker to send them.
            service.perform(withItems: urls)
        } else {
            // No files selected — open Finder's AirDrop window so the user can
            // browse nearby devices. This is the same approach Path Finder and
            // other third-party file managers use; there is no public API to
            // embed the AirDrop device browser in a non-Finder app.
            let airdropApp =
                URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
            NSWorkspace.shared.open(airdropApp)
        }
    }

    // MARK: - ScoutDrop

    private func startScoutDrop() {
        let nickname = PersistenceService.shared.loadScoutDropNickname()
        let deviceID = PersistenceService.shared.loadScoutDropDeviceID()

        // Start advertising and browsing on the ScoutDrop actor.
        Task {
            await scoutDropService.startAdvertising(nickname: nickname, deviceID: deviceID)
            await scoutDropService.startBrowsing()
        }

        // Consume peer updates and push them to the sidebar.
        scoutDropPeerTask = Task { [weak self] in
            guard let self else { return }
            for await peers in self.scoutDropService.peers {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.sidebarViewController.updateNearbyPeers(peers)
                }
            }
        }

        // Consume incoming offers and show accept/decline alerts.
        scoutDropOfferTask = Task { [weak self] in
            guard let self else { return }
            for await offer in self.scoutDropService.incomingOffers {
                guard !Task.isCancelled else { return }
                await self.showIncomingOfferAlert(offer)
            }
        }

        // Consume outgoing verification codes and show them to the sender.
        scoutDropVerificationTask = Task { [weak self] in
            guard let self else { return }
            for await(peerName, code) in self.scoutDropService.outgoingVerifications {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Sending to \(peerName)"
                    let formatted = ScoutDropOffer.formatCode(code)
                    alert.informativeText = "Verification code: \(formatted)\nTell the recipient this code to confirm."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private func showIncomingOfferAlert(_ offer: ScoutDropOffer) async {
        let isTrusted = !offer.senderDeviceID.isEmpty
            && PersistenceService.shared.isScoutDropPeerTrusted(deviceID: offer.senderDeviceID)

        // TOFU certificate pinning: verify the peer's public key hash against the stored hash.
        if isTrusted, let peerHash = offer.peerPublicKeyHash {
            let storedHash = PersistenceService.shared.loadScoutDropPeerKeyHash(
                deviceID: offer.senderDeviceID
            )
            if let storedHash, storedHash != peerHash {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Security Warning"
                    alert.informativeText = """
                    The identity of "\(offer.senderName)" has changed since you last \
                    connected. This could mean someone is impersonating this device.\n\n\
                    The transfer has been automatically declined. If this device was \
                    recently reinstalled, remove it from trusted peers and try again.
                    """
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                await scoutDropService.declineOffer(offer.id)
                return
            }
        }

        await MainActor.run { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "\(offer.senderName) wants to send you files"

            var info = "\(offer.fileCount) item\(offer.fileCount == 1 ? "" : "s") (\(offer.formattedSize))"
            if !isTrusted, !offer.verificationCode.isEmpty {
                info += "\n\nVerification code: \(offer.formattedVerificationCode)"
                info += "\nConfirm this code with the sender before accepting."
            }
            alert.informativeText = info
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Accept")
            alert.addButton(withTitle: "Decline")

            let response = alert.runModal()
            Task {
                if response == .alertFirstButtonReturn {
                    await self.scoutDropService.acceptOffer(offer.id)
                    // Mark peer as trusted after successful acceptance (TOFU).
                    if !isTrusted, !offer.senderDeviceID.isEmpty {
                        PersistenceService.shared.saveScoutDropTrustedPeer(
                            deviceID: offer.senderDeviceID,
                            name: offer.senderName
                        )
                    }
                    // Store the peer's public key hash for TOFU certificate pinning.
                    if let peerHash = offer.peerPublicKeyHash, !offer.senderDeviceID.isEmpty {
                        PersistenceService.shared.saveScoutDropPeerKeyHash(
                            deviceID: offer.senderDeviceID,
                            keyHash: peerHash
                        )
                    }
                } else {
                    await self.scoutDropService.declineOffer(offer.id)
                }
            }
        }
    }

    // MARK: - Recents

    /// Observation token for the recents metadata query notification.
    private static var recentsSearchObserver: NSObjectProtocol?

    /// Strong reference to the in-flight recents query.
    private var recentsSearchQuery: NSMetadataQuery?

    private func showRecents() {
        recentsSearchQuery?.stop()
        recentsSearchQuery = nil

        let query = NSMetadataQuery()
        // Find files opened in the last 7 days, sorted by last used date (descending).
        // Exclude directories — Recents in Finder only shows documents.
        query.predicate = NSPredicate(
            fromMetadataQueryString: "kMDItemLastUsedDate >= $time.today(-7) && kMDItemContentTypeTree != 'public.folder'"
        ) ?? NSPredicate(value: false)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]

        // Remove any previous observer.
        if let previousObserver = Self.recentsSearchObserver {
            NotificationCenter.default.removeObserver(previousObserver)
            Self.recentsSearchObserver = nil
        }

        Self.recentsSearchObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self, weak query] _ in
            guard let self, let query else { return }
            query.stop()
            self.recentsSearchQuery = nil

            if let observer = Self.recentsSearchObserver {
                NotificationCenter.default.removeObserver(observer)
                Self.recentsSearchObserver = nil
            }

            var items: [FileItem] = []
            let limit = min(query.resultCount, 200)
            for i in 0 ..< limit {
                if let result = query.result(at: i) as? NSMetadataItem,
                   let path = result.value(forAttribute: NSMetadataItemPathKey) as? String
                {
                    let url = URL(fileURLWithPath: path)
                    if let fileItem = FileItem.create(from: url, iconStyle: self.iconStyle) {
                        items.append(fileItem)
                    }
                }
            }

            self.browserContainer.activePaneController().displaySearchResults(
                items,
                title: "Recents"
            )
        }

        recentsSearchQuery = query
        query.start()
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
        let escaped = tagName.replacingOccurrences(of: "'", with: "\\'")
        query.predicate = NSPredicate(fromMetadataQueryString: "kMDItemUserTags == '\(escaped)'cd")
            ?? NSPredicate(value: false)
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
            for i in 0 ..< query.resultCount {
                if let result = query.result(at: i) as? NSMetadataItem,
                   let path = result.value(forAttribute: NSMetadataItemPathKey) as? String
                {
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

        tagSearchQuery = query
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
            .settings,
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
        case .settings:
            return makeSettingsItem(identifier: itemIdentifier)
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
            systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar"
        )
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

    private func makeSettingsItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Settings"
        item.paletteLabel = "Settings"
        item.toolTip = "Open Settings"
        item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        item.target = self
        item.action = #selector(settingsAction(_:))
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

    @objc private func togglePreviewAction(_ sender: Any?) {
        togglePreview()
    }

    @objc private func settingsAction(_ sender: Any?) {
        // Walk the responder chain — AppDelegate handles "handleSettings:"
        NSApp.sendAction(NSSelectorFromString("handleSettings:"), to: nil, from: sender)
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

        if query.isEmpty {
            // User cleared the search field — exit search mode
            exitSearch()
            return
        }

        // While typing, do local filtering only
        if isSearchActive {
            // Already in search mode — re-search with updated query
            searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                self?.executeSearch(query: query)
            }
        } else {
            searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.browserContainer.setFilterQuery(query)
            }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let movement = obj.userInfo?["NSTextMovement"] as? Int
        let field = obj.object as? NSSearchField
        // Check if editing ended because the user pressed Enter
        guard let movement, movement == NSReturnTextMovement, let field else { return }

        let query = field.stringValue
        guard !query.isEmpty else { return }

        // Cancel any pending local filter debounce — we're switching to Spotlight search.
        searchDebounceTimer?.invalidate()

        // Enter triggers Spotlight search
        executeSearch(query: query)
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
            if !showPreview, !userDismissedPreview, !item.isDirectory,
               item.isText || item.isImage || item.isPDF || item.isVideo || item.isAudio
            {
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
