import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var mainWindowController: MainWindowController?
    private var eventTap: CFMachPort?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupGlobalHotkey()

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalHotkey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Global Hotkey (Opt+Space)

    private func setupGlobalHotkey() {
        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: globalHotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Scout: Failed to create CGEvent tap for global hotkey. Accessibility permissions may be required.")
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeGlobalHotkey() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    fileprivate func summonApp() {
        NSApp.activate(ignoringOtherApps: true)
        if mainWindowController?.window?.isVisible != true {
            mainWindowController?.showWindow(nil)
        }
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
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
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let appName = ProcessInfo.processInfo.processName

        appMenu.addItem(NSMenuItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())

        let preferencesItem = NSMenuItem(title: "Settings...", action: nil, keyEquivalent: ",")
        appMenu.addItem(preferencesItem)
        appMenu.addItem(NSMenuItem.separator())

        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    // MARK: - File Menu

    private func buildFileMenu() -> NSMenuItem {
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(handleNewTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(newTabItem)

        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(handleCloseTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(closeTabItem)

        fileMenu.addItem(NSMenuItem.separator())

        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(handleNewWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(newWindowItem)

        fileMenu.addItem(NSMenuItem.separator())

        let closeWindowItem = NSMenuItem(title: "Close Window", action: #selector(handleCloseWindow(_:)), keyEquivalent: "W")
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindowItem)

        fileMenuItem.submenu = fileMenu
        return fileMenuItem
    }

    // MARK: - Edit Menu

    private func buildEditMenu() -> NSMenuItem {
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(NSMenuItem.separator())

        let searchItem = NSMenuItem(title: "Search...", action: #selector(handleSearch(_:)), keyEquivalent: "f")
        editMenu.addItem(searchItem)

        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    // MARK: - View Menu

    private func buildViewMenu() -> NSMenuItem {
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let toggleDualPaneItem = NSMenuItem(title: "Toggle Dual Pane", action: #selector(handleToggleDualPane(_:)), keyEquivalent: "d")
        viewMenu.addItem(toggleDualPaneItem)

        let togglePreviewItem = NSMenuItem(title: "Toggle Preview", action: #selector(handleTogglePreview(_:)), keyEquivalent: " ")
        togglePreviewItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(togglePreviewItem)

        viewMenu.addItem(NSMenuItem.separator())

        let commandPaletteItem = NSMenuItem(title: "Command Palette...", action: #selector(handleCommandPalette(_:)), keyEquivalent: "P")
        commandPaletteItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(commandPaletteItem)

        viewMenu.addItem(NSMenuItem.separator())

        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }

    // MARK: - Go Menu

    private func buildGoMenu() -> NSMenuItem {
        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")

        let goToPathItem = NSMenuItem(title: "Go to Path...", action: #selector(handleGoToPath(_:)), keyEquivalent: "l")
        goMenu.addItem(goToPathItem)

        goMenu.addItem(NSMenuItem.separator())

        goMenu.addItem(NSMenuItem(title: "Home", action: #selector(handleGoHome(_:)), keyEquivalent: "H"))
        goMenu.addItem(NSMenuItem(title: "Desktop", action: #selector(handleGoDesktop(_:)), keyEquivalent: ""))
        goMenu.addItem(NSMenuItem(title: "Documents", action: #selector(handleGoDocuments(_:)), keyEquivalent: ""))
        goMenu.addItem(NSMenuItem(title: "Downloads", action: #selector(handleGoDownloads(_:)), keyEquivalent: ""))

        goMenuItem.submenu = goMenu
        return goMenuItem
    }

    // MARK: - Window Menu

    private func buildWindowMenu() -> NSMenuItem {
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")

        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))

        NSApp.windowsMenu = windowMenu

        windowMenuItem.submenu = windowMenu
        return windowMenuItem
    }

    // MARK: - Help Menu

    private func buildHelpMenu() -> NSMenuItem {
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")

        let appName = ProcessInfo.processInfo.processName
        helpMenu.addItem(NSMenuItem(title: "\(appName) Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?"))

        NSApp.helpMenu = helpMenu

        helpMenuItem.submenu = helpMenu
        return helpMenuItem
    }

    // MARK: - Menu Actions

    @objc private func handleNewTab(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleCloseTab(_ sender: Any?) {
        // Will be dispatched to the active window controller via responder chain
    }

    @objc private func handleNewWindow(_ sender: Any?) {
        let controller = MainWindowController()
        controller.showWindow(nil)
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

// MARK: - Global Hotkey Callback

private func globalHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    // Opt+Space: keyCode 49 = Space, check for Option flag without Command/Control/Shift
    let optionOnly: CGEventFlags = .maskAlternate
    let unwantedFlags: CGEventFlags = [.maskCommand, .maskControl, .maskShift]

    if keyCode == 49,
       flags.contains(optionOnly),
       flags.intersection(unwantedFlags).isEmpty
    {
        guard let userInfo = userInfo else {
            return Unmanaged.passRetained(event)
        }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            delegate.summonApp()
        }
        // Consume the event so it does not propagate
        return nil
    }

    return Unmanaged.passRetained(event)
}

