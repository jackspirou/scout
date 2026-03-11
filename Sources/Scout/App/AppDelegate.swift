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

final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var windowControllers: [MainWindowController] = []

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupGlobalHotkey()

        let controller = makeWindowController()
        controller.showWindow(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalHotkey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
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
            .item("Settings...", action: nil, key: ","),
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
            .separator,
            .item("New Window", action: #selector(handleNewWindow(_:)), key: "n"),
            .separator,
            .item("Close Window", action: #selector(handleCloseWindow(_:)), key: "W", modifiers: [.command, .shift]),
        ])
    }

    // MARK: - Edit Menu

    private func buildEditMenu() -> NSMenuItem {
        buildMenu(title: "Edit", items: [
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
                key: "d",
                modifiers: [.command, .shift]
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
    }

    // MARK: - View Menu

    private func buildViewMenu() -> NSMenuItem {
        buildMenu(title: "View", items: [
            .item("Toggle Dual Pane", action: #selector(handleToggleDualPane(_:)), key: "d"),
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
        buildMenu(title: "Go", items: [
            .item("Go to Path...", action: #selector(handleGoToPath(_:)), key: "l"),
            .separator,
            .item("Home", action: #selector(handleGoHome(_:)), key: "H"),
            .item("Desktop", action: #selector(handleGoDesktop(_:))),
            .item("Documents", action: #selector(handleGoDocuments(_:))),
            .item("Downloads", action: #selector(handleGoDownloads(_:))),
        ])
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
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleCloseTab(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
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
        NSApp.keyWindow?.close()
    }

    @objc private func handleToggleDualPane(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleTogglePreview(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleCommandPalette(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleGoToPath(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleSearch(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleGoHome(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleGoDesktop(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleGoDocuments(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleGoDownloads(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }
}
