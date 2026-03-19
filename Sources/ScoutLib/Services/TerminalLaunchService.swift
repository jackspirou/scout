import AppKit

// MARK: - TerminalApp

enum TerminalApp: String, CaseIterable {
    case terminal = "Terminal"
    case iterm2 = "iTerm"
    case warp = "Warp"
    case kitty = "kitty"
    case ghostty = "Ghostty"
    case alacritty = "Alacritty"

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm2: return "com.googlecode.iterm2"
        case .warp: return "dev.warp.Warp-Stable"
        case .kitty: return "net.kovidgoyal.kitty"
        case .ghostty: return "com.mitchellh.ghostty"
        case .alacritty: return "org.alacritty"
        }
    }

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2: return "iTerm2"
        case .warp: return "Warp"
        case .kitty: return "Kitty"
        case .ghostty: return "Ghostty"
        case .alacritty: return "Alacritty"
        }
    }
}

// MARK: - TerminalLaunchService

enum TerminalLaunchService {
    private static let defaultTerminalKey = "scout.defaultTerminal"

    // MARK: - Public API

    static var preferredTerminal: TerminalApp {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultTerminalKey) ?? ""
            return TerminalApp(rawValue: raw) ?? .terminal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultTerminalKey)
        }
    }

    static func installedTerminals() -> [TerminalApp] {
        TerminalApp.allCases.filter { app in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) != nil
        }
    }

    static func openTerminal(at url: URL) {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let app = preferredTerminal

        // If preferred terminal isn't installed, fall back to Terminal.app
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) != nil else {
            openWithTerminalApp(directory)
            return
        }

        switch app {
        case .terminal:
            openWithTerminalApp(directory)
        case .iterm2:
            openWithITerm2(directory)
        default:
            openGeneric(app: app, directory: directory)
        }
    }

    // MARK: - Launch Methods

    private static func openWithTerminalApp(_ directory: URL) {
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(shellEscape(directory.path))"
        end tell
        """
        runAppleScript(script)
    }

    private static func openWithITerm2(_ directory: URL) {
        let script = """
        tell application "iTerm"
            activate
            create window with default profile command "cd \(shellEscape(directory.path)) && clear"
        end tell
        """
        runAppleScript(script)
    }

    private static func openGeneric(app: TerminalApp, directory: URL) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else {
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = []
        config.environment = ["PWD": directory.path]

        // Open the app with the directory as the URL to open
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: appURL,
            configuration: config
        )
    }

    // MARK: - Helpers

    private static func shellEscape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }
}
