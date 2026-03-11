import Cocoa
import UniformTypeIdentifiers

/// Builds context menus for the file list view, extracting menu construction
/// logic from `FileListViewController` while keeping `@objc` action methods
/// on the view controller (responder chain).
enum FileListContextMenuBuilder {
    // MARK: - Selectors (mirror the @objc methods on FileListViewController)

    private static let openSelector = #selector(FileListViewController.contextOpen(_:))
    private static let openWithSelector = #selector(FileListViewController.contextOpenWith(_:))
    private static let getInfoSelector = #selector(FileListViewController.contextGetInfo(_:))
    private static let renameSelector = #selector(FileListViewController.contextRename(_:))
    private static let copySelector = #selector(FileListViewController.contextCopy(_:))
    private static let copyPathSelector = #selector(FileListViewController.contextCopyPath(_:))
    private static let cutSelector = #selector(FileListViewController.contextCut(_:))
    private static let pasteSelector = #selector(FileListViewController.contextPaste(_:))
    private static let duplicateSelector = #selector(FileListViewController.contextDuplicate(_:))
    private static let moveToTrashSelector = #selector(FileListViewController.contextMoveToTrash(_:))
    private static let quickLookSelector = #selector(FileListViewController.contextQuickLook(_:))
    private static let showInFinderSelector = #selector(FileListViewController.contextShowInFinder(_:))
    private static let compressSelector = #selector(FileListViewController.contextCompress(_:))
    private static let newFolderSelector = #selector(FileListViewController.contextNewFolder(_:))

    // MARK: - Public API

    /// Builds the context menu for selected file items.
    static func buildContextMenu(
        items: [FileItem],
        target: AnyObject,
        menuDelegate: NSMenuDelegate? = nil
    ) -> NSMenu {
        let menu = NSMenu()

        // Open
        let openItem = NSMenuItem(title: "Open", action: openSelector, keyEquivalent: "")
        openItem.target = target
        menu.addItem(openItem)

        // Open With submenu (populated lazily when the submenu is opened)
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let openWithSubmenu = NSMenu()
        openWithSubmenu.delegate = menuDelegate
        openWithItem.submenu = openWithSubmenu
        openWithItem.representedObject = items
        menu.addItem(openWithItem)

        menu.addItem(NSMenuItem.separator())

        // Get Info
        let getInfoItem = NSMenuItem(title: "Get Info", action: getInfoSelector, keyEquivalent: "")
        getInfoItem.target = target
        menu.addItem(getInfoItem)

        menu.addItem(NSMenuItem.separator())

        // Rename
        let renameItem = NSMenuItem(title: "Rename", action: renameSelector, keyEquivalent: "")
        renameItem.target = target
        menu.addItem(renameItem)

        // Copy
        let copyItem = NSMenuItem(title: "Copy", action: copySelector, keyEquivalent: "c")
        copyItem.target = target
        copyItem.keyEquivalentModifierMask = [.command]
        menu.addItem(copyItem)

        // Copy Path
        let copyPathItem = NSMenuItem(title: "Copy Path", action: copyPathSelector, keyEquivalent: "c")
        copyPathItem.target = target
        copyPathItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(copyPathItem)

        // Cut
        let cutItem = NSMenuItem(title: "Cut", action: cutSelector, keyEquivalent: "x")
        cutItem.target = target
        cutItem.keyEquivalentModifierMask = [.command]
        menu.addItem(cutItem)

        // Paste
        let pasteItem = NSMenuItem(title: "Paste", action: pasteSelector, keyEquivalent: "v")
        pasteItem.target = target
        pasteItem.keyEquivalentModifierMask = [.command]
        menu.addItem(pasteItem)

        // Duplicate
        let duplicateItem = NSMenuItem(title: "Duplicate", action: duplicateSelector, keyEquivalent: "")
        duplicateItem.target = target
        menu.addItem(duplicateItem)

        menu.addItem(NSMenuItem.separator())

        // Move to Trash
        let trashItem = NSMenuItem(title: "Move to Trash", action: moveToTrashSelector, keyEquivalent: "\u{8}")
        trashItem.target = target
        trashItem.keyEquivalentModifierMask = [.command]
        menu.addItem(trashItem)

        menu.addItem(NSMenuItem.separator())

        // Quick Look
        let quickLookItem = NSMenuItem(title: "Quick Look", action: quickLookSelector, keyEquivalent: " ")
        quickLookItem.target = target
        menu.addItem(quickLookItem)

        // Show in Finder
        let showInFinderItem = NSMenuItem(title: "Show in Finder", action: showInFinderSelector, keyEquivalent: "")
        showInFinderItem.target = target
        menu.addItem(showInFinderItem)

        menu.addItem(NSMenuItem.separator())

        // Compress
        let compressItem = NSMenuItem(title: "Compress", action: compressSelector, keyEquivalent: "")
        compressItem.target = target
        menu.addItem(compressItem)

        // Share submenu (populated lazily when opened)
        let shareItem = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        let shareSubmenu = NSMenu()
        shareSubmenu.delegate = menuDelegate
        shareItem.submenu = shareSubmenu
        shareItem.representedObject = items
        menu.addItem(shareItem)

        menu.addItem(NSMenuItem.separator())

        // New Folder
        let newFolderItem = NSMenuItem(title: "New Folder", action: newFolderSelector, keyEquivalent: "")
        newFolderItem.target = target
        menu.addItem(newFolderItem)

        return menu
    }

    /// Builds the background menu shown when right-clicking empty space.
    static func buildBackgroundMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu()

        let newFolderItem = NSMenuItem(title: "New Folder", action: newFolderSelector, keyEquivalent: "")
        newFolderItem.target = target
        menu.addItem(newFolderItem)

        let pasteItem = NSMenuItem(title: "Paste", action: pasteSelector, keyEquivalent: "v")
        pasteItem.target = target
        pasteItem.keyEquivalentModifierMask = [.command]
        menu.addItem(pasteItem)

        let showInFinderItem = NSMenuItem(title: "Show in Finder", action: showInFinderSelector, keyEquivalent: "")
        showInFinderItem.target = target
        menu.addItem(showInFinderItem)

        return menu
    }

    /// Populates the "Open With" submenu lazily.
    static func populateOpenWithSubmenu(_ menu: NSMenu, items: [FileItem], target: AnyObject) {
        menu.removeAllItems()

        guard let firstItem = items.first else { return }

        let appURLs: [URL]
        if let contentType = UTType(filenameExtension: firstItem.url.pathExtension) {
            appURLs = NSWorkspace.shared.urlsForApplications(toOpen: contentType)
        } else {
            appURLs = []
        }

        for appURL in appURLs.prefix(20) {
            let appName = FileManager.default.displayName(atPath: appURL.path)
            let menuItem = NSMenuItem(title: appName, action: openWithSelector, keyEquivalent: "")
            menuItem.target = target
            menuItem.representedObject = appURL
            menuItem.image = NSWorkspace.shared.icon(forFile: appURL.path)
            menuItem.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(menuItem)
        }

        if menu.items.isEmpty {
            let noneItem = NSMenuItem(title: "No Applications Found", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        }
    }

    /// Populates the Share submenu lazily using NSSharingServicePicker.
    static func populateShareSubmenu(_ menu: NSMenu, items: [FileItem], target: AnyObject) {
        menu.removeAllItems()

        let urls = items.map(\.url)
        let picker = NSSharingServicePicker(items: urls)
        let standardItem = picker.standardShareMenuItem
        // The standard share menu item contains a submenu with all available services.
        if let shareSubmenu = standardItem.submenu {
            for item in shareSubmenu.items {
                shareSubmenu.removeItem(item)
                menu.addItem(item)
            }
        } else {
            menu.addItem(standardItem)
        }
    }
}
