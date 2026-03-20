import AppKit
import Foundation

// MARK: - FullDiskAccessService

/// Checks whether the app has Full Disk Access and provides a way to open
/// System Settings. Full Disk Access is needed because Scout is a file manager
/// that must browse all directories, including TCC-protected paths.
///
/// Detection uses multiple TCC-protected paths for resilience across macOS
/// versions. The first check also auto-registers the app in the FDA list in
/// System Settings, so the user can toggle it without manually browsing for it.
final class FullDiskAccessService {
    // MARK: - Singleton

    static let shared = FullDiskAccessService()

    // MARK: - Public API

    /// Returns `true` if the app currently has Full Disk Access.
    ///
    /// Checks multiple TCC-protected paths for resilience across macOS versions:
    /// 1. `~/Library/Containers/com.apple.stocks` — reliable on macOS 12+ (Monterey through Sequoia)
    /// 2. `~/Library/Safari/Bookmarks.plist` — fallback for older or non-standard setups
    func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        // Primary: ~/Library/Containers/com.apple.stocks (TCC-protected on macOS 12+)
        let stocksContainer = home.appendingPathComponent("Library/Containers/com.apple.stocks")
        if let _ = try? fm.contentsOfDirectory(atPath: stocksContainer.path) {
            return true
        }

        // Fallback: ~/Library/Safari/Bookmarks.plist (TCC-protected on macOS 10.14+)
        let safariBookmarks = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
        if fm.isReadableFile(atPath: safariBookmarks.path) {
            return true
        }

        return false
    }

    /// Opens the Full Disk Access pane in System Settings.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
