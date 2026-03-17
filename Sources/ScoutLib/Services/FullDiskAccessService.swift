import AppKit
import Foundation

// MARK: - FullDiskAccessService

/// Checks whether the app has Full Disk Access and prompts the user if not.
/// Full Disk Access is needed because Scout is a file manager that must browse
/// all directories, including TCC-protected paths.
///
/// Detection uses multiple TCC-protected paths for resilience across macOS
/// versions. The first check also auto-registers the app in the FDA list in
/// System Settings, so the user can toggle it without manually browsing for it.
final class FullDiskAccessService {
    // MARK: - Singleton

    static let shared = FullDiskAccessService()

    // MARK: - UserDefaults Keys

    private let dismissedKey = "fullDiskAccessDismissedAt"
    private let dismissedVersionKey = "fullDiskAccessDismissedVersion"

    // MARK: - Constants

    /// Re-prompt after one week even if the user dismissed.
    private let repromptInterval: TimeInterval = 7 * 24 * 60 * 60

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

    /// Shows the FDA prompt if access is missing and the user hasn't recently dismissed it.
    func promptIfNeeded() {
        guard !hasFullDiskAccess() else { return }
        guard shouldPrompt() else { return }
        showPrompt()
    }

    /// Opens the Full Disk Access pane in System Settings.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private func shouldPrompt() -> Bool {
        let defaults = UserDefaults.standard

        // Re-prompt on version change regardless of dismissal
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let dismissedVersion = defaults.string(forKey: dismissedVersionKey) ?? ""
        if currentVersion != dismissedVersion {
            return true
        }

        // Re-prompt after the reprompt interval
        let dismissedAt = defaults.double(forKey: dismissedKey)
        if dismissedAt == 0 { return true }
        return Date().timeIntervalSince1970 - dismissedAt >= repromptInterval
    }

    private func recordDismissal() {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: dismissedKey)
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        defaults.set(currentVersion, forKey: dismissedVersionKey)
    }

    private func showPrompt() {
        let alert = NSAlert()
        alert.messageText = "Full Disk Access Required"
        alert.informativeText = "Scout is a file manager that needs access to browse all your files and folders. "
            + "Without Full Disk Access, macOS will prompt you separately for each protected folder.\n\n"
            + "Grant access in System Settings, then relaunch Scout."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.icon = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Full Disk Access")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
        recordDismissal()
    }
}
