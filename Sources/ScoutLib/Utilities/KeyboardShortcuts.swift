import AppKit
import Foundation

// MARK: - KeyboardShortcut

/// Represents a single keyboard shortcut binding.
struct KeyboardShortcut: Identifiable {
    let id: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let action: String
    let category: ShortcutCategory

    init(
        key: String,
        modifiers: NSEvent.ModifierFlags = [],
        action: String,
        category: ShortcutCategory = .general
    ) {
        id = action
        self.key = key
        self.modifiers = modifiers
        self.action = action
        self.category = category
    }
}

// MARK: - ShortcutCategory

enum ShortcutCategory: String, CaseIterable {
    case navigation = "Navigation"
    case fileOperations = "File Operations"
    case view = "View"
    case selection = "Selection"
    case general = "General"
    case vim = "Vim Mode"
}

// MARK: - KeyboardShortcuts

/// Defines all keyboard shortcuts used in Scout.
enum KeyboardShortcuts {
    // MARK: - Navigation

    static let navigateBack = KeyboardShortcut(
        key: "[",
        modifiers: .command,
        action: "navigateBack",
        category: .navigation
    )

    static let navigateForward = KeyboardShortcut(
        key: "]",
        modifiers: .command,
        action: "navigateForward",
        category: .navigation
    )

    static let goToParent = KeyboardShortcut(
        key: String(Unicode.Scalar(NSUpArrowFunctionKey)!),
        modifiers: .command,
        action: "goToParent",
        category: .navigation
    )

    static let openItem = KeyboardShortcut(
        key: String(Unicode.Scalar(NSDownArrowFunctionKey)!),
        modifiers: .command,
        action: "openItem",
        category: .navigation
    )

    static let goToHome = KeyboardShortcut(
        key: "h",
        modifiers: [.command, .shift],
        action: "goToHome",
        category: .navigation
    )

    static let goToDesktop = KeyboardShortcut(
        key: "d",
        modifiers: [.command, .shift],
        action: "goToDesktop",
        category: .navigation
    )

    static let goToDownloads = KeyboardShortcut(
        key: "l",
        modifiers: [.command, .option],
        action: "goToDownloads",
        category: .navigation
    )

    static let goToDocuments = KeyboardShortcut(
        key: "o",
        modifiers: [.command, .shift],
        action: "goToDocuments",
        category: .navigation
    )

    static let goToFolder = KeyboardShortcut(
        key: "g",
        modifiers: [.command, .shift],
        action: "goToFolder",
        category: .navigation
    )

    // MARK: - File Operations

    static let newFolder = KeyboardShortcut(
        key: "n",
        modifiers: [.command, .shift],
        action: "newFolder",
        category: .fileOperations
    )

    static let newFile = KeyboardShortcut(
        key: "n",
        modifiers: [.command, .option],
        action: "newFile",
        category: .fileOperations
    )

    static let rename = KeyboardShortcut(
        key: String(Unicode.Scalar(NSF2FunctionKey)!),
        modifiers: [],
        action: "rename",
        category: .fileOperations
    )

    static let renameWithReturn = KeyboardShortcut(
        key: "\r",
        modifiers: [],
        action: "rename",
        category: .fileOperations
    )

    static let duplicate = KeyboardShortcut(
        key: "d",
        modifiers: .command,
        action: "duplicate",
        category: .fileOperations
    )

    static let moveToTrash = KeyboardShortcut(
        key: String(Unicode.Scalar(NSDeleteCharacter)!),
        modifiers: .command,
        action: "moveToTrash",
        category: .fileOperations
    )

    static let cut = KeyboardShortcut(
        key: "x",
        modifiers: .command,
        action: "cut",
        category: .fileOperations
    )

    static let copy = KeyboardShortcut(
        key: "c",
        modifiers: .command,
        action: "copy",
        category: .fileOperations
    )

    static let paste = KeyboardShortcut(
        key: "v",
        modifiers: .command,
        action: "paste",
        category: .fileOperations
    )

    static let getInfo = KeyboardShortcut(
        key: "i",
        modifiers: .command,
        action: "getInfo",
        category: .fileOperations
    )

    static let quickLook = KeyboardShortcut(
        key: " ",
        modifiers: [],
        action: "quickLook",
        category: .fileOperations
    )

    // MARK: - View

    static let toggleHiddenFiles = KeyboardShortcut(
        key: ".",
        modifiers: [.command, .shift],
        action: "toggleHiddenFiles",
        category: .view
    )

    static let viewAsList = KeyboardShortcut(
        key: "1",
        modifiers: .command,
        action: "viewAsList",
        category: .view
    )

    static let viewAsIcons = KeyboardShortcut(
        key: "2",
        modifiers: .command,
        action: "viewAsIcons",
        category: .view
    )

    static let viewAsColumns = KeyboardShortcut(
        key: "3",
        modifiers: .command,
        action: "viewAsColumns",
        category: .view
    )

    static let viewAsGallery = KeyboardShortcut(
        key: "4",
        modifiers: .command,
        action: "viewAsGallery",
        category: .view
    )

    static let toggleSidebar = KeyboardShortcut(
        key: "s",
        modifiers: [.command, .option],
        action: "toggleSidebar",
        category: .view
    )

    static let togglePreview = KeyboardShortcut(
        key: "p",
        modifiers: [.command, .option],
        action: "togglePreview",
        category: .view
    )

    static let zoomIn = KeyboardShortcut(
        key: "=",
        modifiers: .command,
        action: "zoomIn",
        category: .view
    )

    static let zoomOut = KeyboardShortcut(
        key: "-",
        modifiers: .command,
        action: "zoomOut",
        category: .view
    )

    // MARK: - Selection

    static let selectAll = KeyboardShortcut(
        key: "a",
        modifiers: .command,
        action: "selectAll",
        category: .selection
    )

    static let deselectAll = KeyboardShortcut(
        key: "a",
        modifiers: [.command, .shift],
        action: "deselectAll",
        category: .selection
    )

    // MARK: - General

    static let find = KeyboardShortcut(
        key: "f",
        modifiers: .command,
        action: "find",
        category: .general
    )

    static let newTab = KeyboardShortcut(
        key: "t",
        modifiers: .command,
        action: "newTab",
        category: .general
    )

    static let closeTab = KeyboardShortcut(
        key: "w",
        modifiers: .command,
        action: "closeTab",
        category: .general
    )

    static let nextTab = KeyboardShortcut(
        key: "}",
        modifiers: [.command, .shift],
        action: "nextTab",
        category: .general
    )

    static let previousTab = KeyboardShortcut(
        key: "{",
        modifiers: [.command, .shift],
        action: "previousTab",
        category: .general
    )

    static let preferences = KeyboardShortcut(
        key: ",",
        modifiers: .command,
        action: "preferences",
        category: .general
    )

    // MARK: - Vim Mode Bindings

    static let vimDown = KeyboardShortcut(
        key: "j",
        modifiers: [],
        action: "moveDown",
        category: .vim
    )

    static let vimUp = KeyboardShortcut(
        key: "k",
        modifiers: [],
        action: "moveUp",
        category: .vim
    )

    static let vimLeft = KeyboardShortcut(
        key: "h",
        modifiers: [],
        action: "moveLeft",
        category: .vim
    )

    static let vimRight = KeyboardShortcut(
        key: "l",
        modifiers: [],
        action: "moveRight",
        category: .vim
    )

    static let vimTop = KeyboardShortcut(
        key: "g",
        modifiers: [],
        action: "moveToTop",
        category: .vim
    )

    static let vimBottom = KeyboardShortcut(
        key: "G",
        modifiers: .shift,
        action: "moveToBottom",
        category: .vim
    )

    static let vimOpen = KeyboardShortcut(
        key: "o",
        modifiers: [],
        action: "openItem",
        category: .vim
    )

    // MARK: - All Shortcuts

    /// All default shortcuts, excluding vim mode bindings.
    static let allDefaults: [KeyboardShortcut] = [
        navigateBack, navigateForward, goToParent, openItem,
        goToHome, goToDesktop, goToDownloads, goToDocuments, goToFolder,
        newFolder, newFile, rename, renameWithReturn, duplicate, moveToTrash,
        cut, copy, paste, getInfo, quickLook,
        toggleHiddenFiles, viewAsList, viewAsIcons, viewAsColumns, viewAsGallery,
        toggleSidebar, togglePreview, zoomIn, zoomOut,
        selectAll, deselectAll,
        find, newTab, closeTab, nextTab, previousTab, preferences,
    ]

    /// Vim mode bindings.
    static let vimBindings: [KeyboardShortcut] = [
        vimDown, vimUp, vimLeft, vimRight, vimTop, vimBottom, vimOpen,
    ]
}

// MARK: - ShortcutMatcher

/// Matches keyboard events to registered shortcuts.
struct ShortcutMatcher {
    /// Whether vim mode is enabled.
    var vimModeEnabled: Bool

    init(vimModeEnabled: Bool = false) {
        self.vimModeEnabled = vimModeEnabled
    }

    /// Returns the matching shortcut action for a given keyboard event, or nil if none match.
    func match(event: NSEvent) -> String? {
        guard event.type == .keyDown else { return nil }

        let characters = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Check standard shortcuts first.
        for shortcut in KeyboardShortcuts.allDefaults {
            if matches(shortcut: shortcut, characters: characters, modifiers: modifiers) {
                return shortcut.action
            }
        }

        // Check vim bindings if enabled.
        if vimModeEnabled {
            for shortcut in KeyboardShortcuts.vimBindings {
                if matches(shortcut: shortcut, characters: characters, modifiers: modifiers) {
                    return shortcut.action
                }
            }
        }

        return nil
    }

    /// Returns all shortcuts grouped by category.
    func allShortcuts() -> [ShortcutCategory: [KeyboardShortcut]] {
        var grouped: [ShortcutCategory: [KeyboardShortcut]] = [:]

        for shortcut in KeyboardShortcuts.allDefaults {
            grouped[shortcut.category, default: []].append(shortcut)
        }

        if vimModeEnabled {
            for shortcut in KeyboardShortcuts.vimBindings {
                grouped[shortcut.category, default: []].append(shortcut)
            }
        }

        return grouped
    }

    // MARK: - Private

    private func matches(
        shortcut: KeyboardShortcut,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let shortcutModifiers = shortcut.modifiers.intersection(.deviceIndependentFlagsMask)

        guard modifiers == shortcutModifiers else { return false }

        return characters == shortcut.key
    }
}

// MARK: - Vim Mode Preference

enum VimModePreference {
    private static let key = "scout.vimModeEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
