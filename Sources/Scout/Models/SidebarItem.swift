import Cocoa

// MARK: - SidebarSection

/// Sections displayed in the sidebar outline view.
enum SidebarSection: String, CaseIterable {
    case favorites = "Favorites"
    case iCloud = "iCloud"
    case locations = "Locations"
    case tags = "Tags"
}

// MARK: - SidebarItem

/// A single item in the sidebar. Uses class (reference) semantics because
/// NSOutlineView relies on object identity for item tracking.
final class SidebarItem {
    let url: URL
    let name: String
    let icon: NSImage
    let section: SidebarSection

    init(url: URL, name: String, icon: NSImage, section: SidebarSection) {
        self.url = url
        self.name = name
        self.icon = icon
        self.section = section
    }
}
