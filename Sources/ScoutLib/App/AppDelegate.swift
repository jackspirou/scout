import AppKit

// MARK: - Menu Item Descriptor

private struct MenuItemDescriptor {
    let title: String
    let action: Selector?
    let keyEquivalent: String
    let modifierMask: NSEvent.ModifierFlags?
    let submenuItems: [MenuItemDescriptor]?
    let isSeparator: Bool

    static func item(
        _ title: String,
        action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags? = nil
    ) -> MenuItemDescriptor {
        MenuItemDescriptor(
            title: title, action: action, keyEquivalent: key,
            modifierMask: modifiers, submenuItems: nil, isSeparator: false
        )
    }

    static var separator: MenuItemDescriptor {
        MenuItemDescriptor(
            title: "", action: nil, keyEquivalent: "",
            modifierMask: nil, submenuItems: nil, isSeparator: true
        )
    }

    static func submenu(_ title: String, items: [MenuItemDescriptor]) -> MenuItemDescriptor {
        MenuItemDescriptor(
            title: title, action: nil, keyEquivalent: "",
            modifierMask: nil, submenuItems: items, isSeparator: false
        )
    }
}

private func buildNSMenuItem(from descriptor: MenuItemDescriptor) -> NSMenuItem {
    if descriptor.isSeparator { return NSMenuItem.separator() }

    let item = NSMenuItem(title: descriptor.title, action: descriptor.action, keyEquivalent: descriptor.keyEquivalent)
    if let modifiers = descriptor.modifierMask {
        item.keyEquivalentModifierMask = modifiers
    }
    if let children = descriptor.submenuItems {
        let sub = NSMenu(title: descriptor.title)
        for child in children {
            sub.addItem(buildNSMenuItem(from: child))
        }
        item.submenu = sub
    }
    return item
}

private func buildMenu(title: String, items: [MenuItemDescriptor]) -> NSMenuItem {
    let menuItem = NSMenuItem()
    let menu = NSMenu(title: title)
    for descriptor in items {
        menu.addItem(buildNSMenuItem(from: descriptor))
    }
    menuItem.submenu = menu
    return menuItem
}

public final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var windowControllers: [MainWindowController] = []
    private var settingsWindowController: SettingsWindowController?
    private var connectToServerController: ConnectToServerWindowController?
    private var goToPathController: GoToPathWindowController?
    private var commandPaletteController: CommandPaletteWindowController?
    private var batchRenameController: BatchRenameWindowController?
    private var recentFoldersMenu: NSMenu?
    private var clipboardHistoryMenu: NSMenu?
    private var workspacesMenu: NSMenu?
    private var workspaceSaveController: WorkspaceSaveWindowController?
    private var workspaceManagerController: WorkspaceManagerWindowController?

    // MARK: - NSApplicationDelegate

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupGlobalHotkey()

        let controller = makeWindowController()
        controller.showWindow(nil)

        // Restore last session state after the window is visible and laid out
        DispatchQueue.main.async {
            Task { @MainActor in
                if let lastSession = await PersistenceService.shared.loadLastSession() {
                    controller.restoreWindowState(lastSession)
                }
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        removeGlobalHotkey()
        saveSessionState()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let existing = windowControllers.first {
                existing.showWindow(nil)
            } else {
                let controller = makeWindowController()
                controller.showWindow(nil)
            }
        }
        return true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }

    // MARK: - Session Persistence

    /// Saves the current window state synchronously via UserDefaults
    /// so it persists even during app termination.
    private func saveSessionState() {
        guard let wc = windowControllers.first else { return }
        let state = wc.captureWindowState()
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: "lastSession")
        }
    }

    // MARK: - Global Hotkey (Opt+Space)

    private func setupGlobalHotkey() {
        HotkeyService.shared.onHotkeyActivated = { [weak self] in
            self?.summonApp()
        }
        do {
            try HotkeyService.shared.register()
        } catch {
            NSLog("Scout: Failed to register global hotkey: %@", error.localizedDescription)
        }
    }

    private func removeGlobalHotkey() {
        HotkeyService.shared.unregister()
    }

    private func summonApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let controller = windowControllers.first {
            if controller.window?.isVisible != true {
                controller.showWindow(nil)
            }
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            let controller = makeWindowController()
            controller.showWindow(nil)
        }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        mainMenu.addItem(buildAppMenu())
        mainMenu.addItem(buildFileMenu())
        mainMenu.addItem(buildEditMenu())
        mainMenu.addItem(buildViewMenu())
        mainMenu.addItem(buildGoMenu())
        mainMenu.addItem(buildWorkspacesMenu())
        mainMenu.addItem(buildWindowMenu())
        mainMenu.addItem(buildHelpMenu())

        NSApp.mainMenu = mainMenu
    }

    // MARK: - App Menu

    private func buildAppMenu() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let menuItem = buildMenu(title: "", items: [
            .item("About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator,
            .item("Settings...", action: #selector(handleSettings(_:)), key: ","),
            .separator,
            .submenu("Services", items: []),
            .separator,
            .item("Hide \(appName)", action: #selector(NSApplication.hide(_:)), key: "h"),
            .item(
                "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                key: "h",
                modifiers: [.command, .option]
            ),
            .item("Show All", action: #selector(NSApplication.unhideAllApplications(_:))),
            .separator,
            .item("Quit \(appName)", action: #selector(NSApplication.terminate(_:)), key: "q"),
        ])

        // Wire up the Services submenu for the system
        let appMenu = menuItem.submenu!
        let servicesItem = appMenu.items.first { $0.title == "Services" }!
        NSApp.servicesMenu = servicesItem.submenu

        return menuItem
    }

    // MARK: - File Menu

    private func buildFileMenu() -> NSMenuItem {
        buildMenu(title: "File", items: [
            .item("New Tab", action: #selector(handleNewTab(_:)), key: "t"),
            .item("Close Tab", action: #selector(handleCloseTab(_:)), key: "w"),
            .separator,
            .item(
                "New Folder",
                action: #selector(FileListViewController.newFolder(_:)),
                key: "n",
                modifiers: [.command, .shift]
            ),
            .separator,
            .item("Rename", action: #selector(FileListViewController.renameSelection(_:))),
            .item("Batch Rename...", action: #selector(handleBatchRename(_:)), key: "R", modifiers: [.command, .shift]),
            .separator,
            .item("New Window", action: #selector(handleNewWindow(_:)), key: "n"),
            .separator,
            .item("Close Window", action: #selector(handleCloseWindow(_:)), key: "W", modifiers: [.command, .shift]),
        ])
    }

    // MARK: - Edit Menu

    private func buildEditMenu() -> NSMenuItem {
        let menuItem = buildMenu(title: "Edit", items: [
            .item("Undo", action: Selector(("undo:")), key: "z"),
            .item("Redo", action: Selector(("redo:")), key: "Z"),
            .separator,
            .item("Cut", action: #selector(NSText.cut(_:)), key: "x"),
            .item("Copy", action: #selector(NSText.copy(_:)), key: "c"),
            .item(
                "Copy Path",
                action: #selector(FileListViewController.copyPathOfSelection(_:)),
                key: "c",
                modifiers: [.command, .option]
            ),
            .item("Paste", action: #selector(NSText.paste(_:)), key: "v"),
            .item(
                "Duplicate",
                action: #selector(FileListViewController.duplicateSelection(_:)),
                key: "d"
            ),
            .item("Select All", action: #selector(NSText.selectAll(_:)), key: "a"),
            .separator,
            .item(
                "Move to Trash",
                action: #selector(FileListViewController.moveToTrash(_:)),
                key: "\u{8}",
                modifiers: [.command]
            ),
            .separator,
            .item("Search...", action: #selector(handleSearch(_:)), key: "f"),
        ])

        // Add a dynamic "Clipboard History" submenu
        let historyMenu = NSMenu(title: "Clipboard History")
        historyMenu.delegate = self
        clipboardHistoryMenu = historyMenu

        let historyItem = NSMenuItem(title: "Clipboard History", action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu

        let editMenu = menuItem.submenu!
        editMenu.addItem(.separator())
        editMenu.addItem(historyItem)

        return menuItem
    }

    // MARK: - View Menu

    private func buildViewMenu() -> NSMenuItem {
        buildMenu(title: "View", items: [
            .item(
                "Toggle Sidebar",
                action: #selector(handleToggleSidebar(_:)),
                key: "s",
                modifiers: [.command, .option]
            ),
            .item(
                "Toggle Preview",
                action: #selector(handleTogglePreview(_:)),
                key: " ",
                modifiers: [.command, .shift]
            ),
            .separator,
            .item(
                "Command Palette...",
                action: #selector(handleCommandPalette(_:)),
                key: "P",
                modifiers: [.command, .shift]
            ),
            .separator,
            .submenu("Icon Style", items: [
                .item("System Icons", action: #selector(handleSystemIcons(_:))),
                .item("Flat Icons", action: #selector(handleFlatIcons(_:))),
            ]),
            .separator,
            .item(
                "Show Hidden Files",
                action: #selector(handleToggleHiddenFiles(_:)),
                key: ".",
                modifiers: [.command, .shift]
            ),
            .separator,
            .item(
                "Enter Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                key: "f",
                modifiers: [.command, .control]
            ),
        ])
    }

    // MARK: - Go Menu

    private func buildGoMenu() -> NSMenuItem {
        let menuItem = buildMenu(title: "Go", items: [
            .item("Go to Path...", action: #selector(handleGoToPath(_:)), key: "l"),
            .separator,
            .item("Home", action: #selector(handleGoHome(_:)), key: "H"),
            .item("Desktop", action: #selector(handleGoDesktop(_:))),
            .item("Documents", action: #selector(handleGoDocuments(_:))),
            .item("Downloads", action: #selector(handleGoDownloads(_:))),
            .separator,
            .item("Connect to Server...", action: #selector(handleConnectToServer(_:)), key: "k"),
        ])

        // Add a dynamic "Recent Folders" submenu
        let recentMenu = NSMenu(title: "Recent Folders")
        recentMenu.delegate = self
        recentFoldersMenu = recentMenu

        let recentItem = NSMenuItem(title: "Recent Folders", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu

        let goMenu = menuItem.submenu!
        goMenu.addItem(.separator())
        goMenu.addItem(recentItem)

        return menuItem
    }

    // MARK: - Workspaces Menu

    private func buildWorkspacesMenu() -> NSMenuItem {
        let menuItem = buildMenu(title: "Workspaces", items: [
            .item(
                "Save Workspace...",
                action: #selector(handleSaveWorkspace(_:)),
                key: "s",
                modifiers: [.command, .control]
            ),
            .item("Manage Workspaces...", action: #selector(handleManageWorkspaces(_:))),
            .separator,
        ])

        // Set up dynamic workspace list via NSMenuDelegate
        let menu = menuItem.submenu!
        menu.delegate = self
        workspacesMenu = menu

        return menuItem
    }

    // MARK: - Window Menu

    private func buildWindowMenu() -> NSMenuItem {
        let menuItem = buildMenu(title: "Window", items: [
            .item("Minimize", action: #selector(NSWindow.miniaturize(_:)), key: "m"),
            .item("Zoom", action: #selector(NSWindow.performZoom(_:))),
            .separator,
            .item("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = menuItem.submenu
        return menuItem
    }

    // MARK: - Help Menu

    private func buildHelpMenu() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let menuItem = buildMenu(title: "Help", items: [
            .item("\(appName) Help", action: #selector(NSApplication.showHelp(_:)), key: "?"),
        ])
        NSApp.helpMenu = menuItem.submenu
        return menuItem
    }

    // MARK: - Menu Actions

    @objc private func handleNewTab(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        windowController.openNewTab()
    }

    @objc private func handleCloseTab(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        windowController.closeCurrentTab()
    }

    @objc private func handleNewWindow(_ sender: Any?) {
        let controller = makeWindowController()
        controller.showWindow(nil)
    }

    private func makeWindowController() -> MainWindowController {
        let controller = MainWindowController()
        windowControllers.append(controller)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose(_:)),
            name: NSWindow.willCloseNotification,
            object: controller.window
        )
        return controller
    }

    @objc private func windowDidClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === closedWindow }
    }

    @objc private func handleCloseWindow(_ sender: Any?) {
        guard let window = NSApp.keyWindow,
              window.windowController is MainWindowController else { return }
        window.close()
    }

    @objc private func handleTogglePreview(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        windowController.togglePreview()
    }

    @objc private func handleToggleSidebar(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        windowController.toggleSidebar()
    }

    @objc private func handleCommandPalette(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        let palette = CommandPaletteWindowController(actions: buildPaletteActions(for: windowController))
        commandPaletteController = palette
        palette.showPalette(relativeTo: windowController.window)
    }

    @objc private func handleGoToPath(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        let goToPath = GoToPathWindowController(
            currentDirectoryURL: windowController.currentURL(),
            onNavigate: { [weak windowController] url in
                windowController?.navigateToURL(url)
            }
        )
        goToPathController = goToPath
        goToPath.showPanel(relativeTo: windowController.window)
    }

    @objc private func handleSearch(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        windowController.focusSearchField()
    }

    @objc private func handleBatchRename(_ sender: Any?) {
        guard let wc = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        let items = wc.selectedItems()
        guard items.count >= 2 else { return }
        let controller = BatchRenameWindowController(fileURLs: items.map(\.url))
        controller.showWindow(nil)
        batchRenameController = controller
    }

    @objc private func handleGoHome(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        windowController.navigateToURL(FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc private func handleGoDesktop(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        windowController.navigateToURL(home.appendingPathComponent("Desktop"))
    }

    @objc private func handleGoDocuments(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        windowController.navigateToURL(home.appendingPathComponent("Documents"))
    }

    @objc private func handleGoDownloads(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        windowController.navigateToURL(home.appendingPathComponent("Downloads"))
    }

    @objc private func handleSettings(_ sender: Any?) {
        if let existing = settingsWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let settings = SettingsWindowController()
        settingsWindowController = settings
        if let window = settings.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(settingsWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
        settings.showWindow(nil)
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) {
        settingsWindowController = nil
    }

    @objc private func handleConnectToServer(_ sender: Any?) {
        if let existing = connectToServerController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ConnectToServerWindowController()
        connectToServerController = controller
        if let window = controller.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(connectToServerWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
        controller.showWindow(nil)
    }

    @objc private func connectToServerWindowWillClose(_ notification: Notification) {
        connectToServerController = nil
    }

    // MARK: - Workspace Actions

    @objc private func handleSaveWorkspace(_ sender: Any?) {
        guard let wc = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        let saveController = WorkspaceSaveWindowController { [weak self, weak wc] name in
            guard self != nil, let wc else { return }
            let state = wc.captureWindowState()
            let existingCount = PersistenceService.shared.listWorkspacesSync().count
            var workspace = Workspace(name: name, windowState: state)
            workspace.sortOrder = existingCount
            Task {
                await PersistenceService.shared.saveWorkspace(workspace)
            }
        }
        workspaceSaveController = saveController
        saveController.showPanel(relativeTo: wc.window)
    }

    @objc private func handleManageWorkspaces(_ sender: Any?) {
        guard let wc = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        let manager = WorkspaceManagerWindowController { [weak wc] workspace in
            var updated = workspace
            updated.lastUsedAt = Date()
            Task {
                await PersistenceService.shared.saveWorkspace(updated)
            }
            wc?.restoreWindowState(workspace.windowState, restoreFrame: false)
        }
        workspaceManagerController = manager
        manager.showWindow(nil)
    }

    @objc private func handleOpenWorkspace(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? Workspace,
              let wc = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        var updated = workspace
        updated.lastUsedAt = Date()
        Task {
            await PersistenceService.shared.saveWorkspace(updated)
        }
        wc.restoreWindowState(workspace.windowState, restoreFrame: false)
    }

    // MARK: - Recent Folders Actions

    @objc func handleRecentLocation(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let wc = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        wc.navigateToURL(url)
    }

    @objc func handleClearRecentLocations(_ sender: Any?) {
        PersistenceService.shared.saveRecentLocations([])
    }

    // MARK: - Clipboard History Actions

    @MainActor @objc func handleRestoreClipboard(_ sender: NSMenuItem) {
        guard let content = sender.representedObject as? ClipboardContent,
              let wc = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        wc.clipboardManager.restoreFromHistory(content)
    }

    @MainActor @objc func handleClearClipboardHistory(_ sender: Any?) {
        guard let wc = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        wc.clipboardManager.clearHistory()
    }

    // MARK: - Hidden Files Action

    @objc private func handleToggleHiddenFiles(_ sender: Any?) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        windowController.toggleShowHiddenFiles()
    }

    // MARK: - Icon Style Actions

    @objc private func handleSystemIcons(_ sender: Any?) {
        setIconStyleForKeyWindow(.system)
    }

    @objc private func handleFlatIcons(_ sender: Any?) {
        setIconStyleForKeyWindow(.flat)
    }

    private func setIconStyleForKeyWindow(_ style: IconStyle) {
        guard let windowController = NSApp.keyWindow?.windowController as? MainWindowController else { return }
        windowController.setIconStyle(style)
    }

    // MARK: - Palette Actions Builder

    private func buildPaletteActions(for windowController: MainWindowController) -> [PaletteAction] {
        [
            PaletteAction(name: "New Tab", shortcut: "⌘T", icon: nil) { [weak windowController] in
                windowController?.openNewTab()
            },
            PaletteAction(name: "Close Tab", shortcut: "⌘W", icon: nil) { [weak windowController] in
                windowController?.closeCurrentTab()
            },
            PaletteAction(name: "Toggle Preview", shortcut: "⇧⌘Space", icon: nil) { [weak windowController] in
                windowController?.togglePreview()
            },
            PaletteAction(name: "Toggle Sidebar", shortcut: "⌥⌘S", icon: nil) { [weak windowController] in
                windowController?.toggleSidebar()
            },
            PaletteAction(name: "Go Home", shortcut: "⇧⌘H", icon: nil) { [weak windowController] in
                windowController?.navigateToURL(FileManager.default.homeDirectoryForCurrentUser)
            },
            PaletteAction(name: "Go to Desktop", shortcut: nil, icon: nil) { [weak windowController] in
                let home = FileManager.default.homeDirectoryForCurrentUser
                windowController?.navigateToURL(home.appendingPathComponent("Desktop"))
            },
            PaletteAction(name: "Go to Documents", shortcut: nil, icon: nil) { [weak windowController] in
                let home = FileManager.default.homeDirectoryForCurrentUser
                windowController?.navigateToURL(home.appendingPathComponent("Documents"))
            },
            PaletteAction(name: "Go to Downloads", shortcut: nil, icon: nil) { [weak windowController] in
                let home = FileManager.default.homeDirectoryForCurrentUser
                windowController?.navigateToURL(home.appendingPathComponent("Downloads"))
            },
            PaletteAction(name: "Search...", shortcut: "⌘F", icon: nil) { [weak windowController] in
                windowController?.focusSearchField()
            },
        ]
    }
}

// MARK: - NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let wc = NSApp.keyWindow?.windowController as? MainWindowController

        // Actions that require a MainWindowController
        let windowRequiredActions: [Selector] = [
            #selector(handleNewTab(_:)),
            #selector(handleCloseTab(_:)),
            #selector(handleTogglePreview(_:)),
            #selector(handleToggleSidebar(_:)),
            #selector(handleToggleHiddenFiles(_:)),
            #selector(handleGoToPath(_:)),
            #selector(handleGoHome(_:)),
            #selector(handleGoDesktop(_:)),
            #selector(handleGoDocuments(_:)),
            #selector(handleGoDownloads(_:)),
            #selector(handleSearch(_:)),
            #selector(handleCommandPalette(_:)),
            #selector(handleSystemIcons(_:)),
            #selector(handleFlatIcons(_:)),
            #selector(handleBatchRename(_:)),
            #selector(handleSaveWorkspace(_:)),
            #selector(handleManageWorkspaces(_:)),
        ]

        if let action = menuItem.action, windowRequiredActions.contains(action), wc == nil {
            return false
        }

        // Close Tab requires more than 1 tab
        if menuItem.action == #selector(handleCloseTab(_:)) {
            guard let wc else { return false }
            return wc.activePaneTabCount > 1
        }

        // Batch Rename requires at least 2 selected items
        if menuItem.action == #selector(handleBatchRename(_:)) {
            guard let wc else { return false }
            return wc.selectedItems().count >= 2
        }

        // Toggle state checkmarks
        if menuItem.action == #selector(handleToggleSidebar(_:)) {
            menuItem.state = (wc?.showSidebar ?? false) ? .on : .off
        }
        if menuItem.action == #selector(handleTogglePreview(_:)) {
            menuItem.state = (wc?.showPreview ?? false) ? .on : .off
        }
        if menuItem.action == #selector(handleToggleHiddenFiles(_:)) {
            menuItem.state = (wc?.showHiddenFiles ?? true) ? .on : .off
        }
        if menuItem.action == #selector(handleSystemIcons(_:)) {
            menuItem.state = (wc?.iconStyle ?? .system) == .system ? .on : .off
        }
        if menuItem.action == #selector(handleFlatIcons(_:)) {
            menuItem.state = (wc?.iconStyle ?? .system) == .flat ? .on : .off
        }

        return true
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === clipboardHistoryMenu {
            updateClipboardHistoryMenu(menu)
            return
        }

        if menu === workspacesMenu {
            updateWorkspacesMenu(menu)
            return
        }

        guard menu === recentFoldersMenu else { return }

        menu.removeAllItems()
        let recents = PersistenceService.shared.loadRecentLocations()

        if recents.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for url in recents {
            let item = NSMenuItem(
                title: url.lastPathComponent,
                action: #selector(handleRecentLocation(_:)),
                keyEquivalent: ""
            )
            item.representedObject = url
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clearItem = NSMenuItem(
            title: "Clear Recent Folders",
            action: #selector(handleClearRecentLocations(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)
    }

    @MainActor private func updateClipboardHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let wc = NSApp.keyWindow?.windowController as? MainWindowController else {
            let emptyItem = NSMenuItem(title: "No History", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        let history = wc.clipboardManager.clipboardHistory()

        if history.isEmpty {
            let emptyItem = NSMenuItem(title: "No History", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for (index, content) in history.enumerated() {
            let title = content.displayDescription
            let item = NSMenuItem(
                title: title,
                action: #selector(handleRestoreClipboard(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            item.representedObject = content
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clearItem = NSMenuItem(
            title: "Clear Clipboard History",
            action: #selector(handleClearClipboardHistory(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)
    }

    private func updateWorkspacesMenu(_ menu: NSMenu) {
        // Keep the first three static items (Save, Manage, Separator)
        // and remove any dynamically added workspace items after them.
        while menu.items.count > 3 {
            menu.removeItem(at: 3)
        }

        let workspaces = PersistenceService.shared.listWorkspacesSync()

        if workspaces.isEmpty {
            let emptyItem = NSMenuItem(title: "No Saved Workspaces", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for workspace in workspaces {
            let item = NSMenuItem(
                title: workspace.name,
                action: #selector(handleOpenWorkspace(_:)),
                keyEquivalent: ""
            )
            item.representedObject = workspace
            item.target = self
            menu.addItem(item)
        }
    }
}
