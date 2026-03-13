import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Scout", category: "FinderHelper")

/// Utilities for interacting with Finder via Apple Events.
enum FinderHelper {
    /// Opens the Finder "Get Info" window for the given file URLs.
    static func showGetInfo(for urls: [URL]) {
        for url in urls {
            // Escape backslashes and double quotes to prevent AppleScript injection.
            let escapedPath = url.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            tell application "Finder"
                open information window of ("\(escapedPath)" as POSIX file as alias)
            end tell
            """
            if let script = NSAppleScript(source: source) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                if let error {
                    logger.debug("AppleScript error for path \(url.path, privacy: .public): \(error)")
                }
            }
        }
    }
}
