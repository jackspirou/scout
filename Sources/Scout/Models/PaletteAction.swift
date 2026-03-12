import Cocoa

// MARK: - PaletteAction

/// Represents a single executable action in the command palette.
struct PaletteAction {
    let name: String
    let shortcut: String?
    let icon: NSImage?
    let handler: () -> Void
}
