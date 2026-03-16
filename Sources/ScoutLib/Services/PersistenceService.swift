import Foundation

// MARK: - PersistenceError

enum PersistenceError: LocalizedError {
    case encodingFailed(String)
    case decodingFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case deleteFailed(String)
    case directoryCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .encodingFailed(detail):
            return "Failed to encode data: \(detail)"
        case let .decodingFailed(detail):
            return "Failed to decode data: \(detail)"
        case let .writeFailed(detail):
            return "Failed to write data: \(detail)"
        case let .readFailed(detail):
            return "Failed to read data: \(detail)"
        case let .deleteFailed(detail):
            return "Failed to delete data: \(detail)"
        case let .directoryCreationFailed(detail):
            return "Failed to create directory: \(detail)"
        }
    }
}

// MARK: - PersistenceService

/// Service for persisting app state using UserDefaults and Codable JSON files.
/// Data is stored in ~/Library/Application Support/Scout/.
final class PersistenceService: PersistenceServiceProtocol, Sendable {
    // MARK: - Shared Instance

    static let shared = PersistenceService()

    // MARK: - Constants

    private enum StoreKey {
        static let viewSettingsPrefix = "viewSettings_"
        static let lastSession = "lastSession"
        static let recentLocations = "recentLocations"
        static let iconStyle = "scout.iconStyle"
        static let showHiddenFiles = "scout.showHiddenFiles"
        static let sidebarFavorites = "scout.sidebarFavorites"
        static let recentServers = "scout.recentServers"
        static let scoutDropNickname = "scout.scoutDropNickname"
        static let scoutDropReceiveDirectory = "scout.scoutDropReceiveDirectory"
        static let scoutDropDeviceID = "scout.scoutDropDeviceID"
        static let scoutDropTrustedPeers = "scout.scoutDropTrustedPeers"
        static let scoutDropPeerKeyHashes = "scout.scoutDropPeerKeyHashes"
    }

    private enum FileName {
        static let workspacesDirectory = "Workspaces"
    }

    // MARK: - Properties

    private let appSupportDirectory: URL
    private let workspacesDirectory: URL
    // UserDefaults is documented as thread-safe; suppress the Sendable diagnostic.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Init

    init(
        suiteName: String? = nil,
        appSupportOverride: URL? = nil
    ) {
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if let override = appSupportOverride {
            appSupportDirectory = override
        } else {
            let paths = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )
            appSupportDirectory =
                paths.first?.appendingPathComponent("Scout", isDirectory: true)
                    ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support/Scout", isDirectory: true)
        }

        workspacesDirectory = appSupportDirectory.appendingPathComponent(
            FileName.workspacesDirectory,
            isDirectory: true
        )

        // Ensure directories exist.
        PersistenceService.ensureDirectoryExists(at: appSupportDirectory)
        PersistenceService.ensureDirectoryExists(at: workspacesDirectory)
    }

    // MARK: - View Settings

    /// Saves view settings for a specific directory.
    func saveViewSettings(for directory: URL, settings: ViewSettings) {
        let key = StoreKey.viewSettingsPrefix + directory.absoluteString
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    /// Loads view settings for a specific directory.
    func loadViewSettings(for directory: URL) -> ViewSettings? {
        let key = StoreKey.viewSettingsPrefix + directory.absoluteString
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(ViewSettings.self, from: data)
    }

    // MARK: - Workspace

    /// Saves a workspace to a JSON file.
    func saveWorkspace(_ workspace: Workspace) async {
        let fileURL = workspaceFileURL(for: workspace.id)
        do {
            let data = try encoder.encode(workspace)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logError("Failed to save workspace \(workspace.id): \(error.localizedDescription)")
        }
    }

    /// Loads a workspace by ID.
    func loadWorkspace(id: UUID) async -> Workspace? {
        let fileURL = workspaceFileURL(for: id)
        return loadDecodable(from: fileURL)
    }

    /// Lists all saved workspaces sorted by most recently updated.
    func listWorkspaces() async -> [Workspace] {
        let fileManager = FileManager.default
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: workspacesDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var workspaces: [Workspace] = []

        for fileURL in contents where fileURL.pathExtension == "json" {
            if let workspace: Workspace = loadDecodable(from: fileURL) {
                workspaces.append(workspace)
            }
        }

        workspaces.sort { $0.updatedAt > $1.updatedAt }
        return workspaces
    }

    /// Deletes a workspace.
    func deleteWorkspace(id: UUID) async {
        let fileURL = workspaceFileURL(for: id)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Session

    /// Saves the last session window state.
    func saveLastSession(_ windowState: WindowState) async {
        guard let data = try? encoder.encode(windowState) else { return }
        defaults.set(data, forKey: StoreKey.lastSession)
    }

    /// Loads the last session window state.
    func loadLastSession() async -> WindowState? {
        guard let data = defaults.data(forKey: StoreKey.lastSession) else { return nil }
        return try? decoder.decode(WindowState.self, from: data)
    }

    // MARK: - Recent Locations

    /// Saves recent locations as bookmark data for security-scoped access.
    func saveRecentLocations(_ urls: [URL]) {
        let bookmarks: [Data] = urls.compactMap { url in
            try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        defaults.set(bookmarks, forKey: StoreKey.recentLocations)
    }

    /// Loads recent locations, resolving bookmark data.
    func loadRecentLocations() -> [URL] {
        guard let bookmarks = defaults.array(forKey: StoreKey.recentLocations) as? [Data] else {
            return []
        }

        return bookmarks.compactMap { data in
            var isStale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            else {
                return nil
            }

            if isStale {
                logError("Stale bookmark for \(url.path)")
            }

            return url
        }
    }

    // MARK: - Icon Style

    func saveIconStyle(_ style: IconStyle) {
        defaults.set(style.rawValue, forKey: StoreKey.iconStyle)
    }

    func loadIconStyle() -> IconStyle {
        guard let raw = defaults.string(forKey: StoreKey.iconStyle),
              let style = IconStyle(rawValue: raw) else { return .system }
        return style
    }

    // MARK: - Show Hidden Files

    func saveShowHiddenFiles(_ show: Bool) {
        defaults.set(show, forKey: StoreKey.showHiddenFiles)
    }

    func loadShowHiddenFiles() -> Bool {
        guard defaults.object(forKey: StoreKey.showHiddenFiles) != nil else { return true }
        return defaults.bool(forKey: StoreKey.showHiddenFiles)
    }

    // MARK: - Sidebar Favorites

    func saveSidebarFavorites(_ urls: [URL]) {
        let bookmarks: [Data] = urls.compactMap { url in
            try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        defaults.set(bookmarks, forKey: StoreKey.sidebarFavorites)
    }

    func loadSidebarFavorites() -> [URL] {
        guard let bookmarks = defaults.array(forKey: StoreKey.sidebarFavorites) as? [Data] else {
            return []
        }

        return bookmarks.compactMap { data in
            var isStale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
    }

    // MARK: - Recent Servers

    func saveRecentServers(_ servers: [String]) {
        defaults.set(servers, forKey: StoreKey.recentServers)
    }

    func loadRecentServers() -> [String] {
        defaults.stringArray(forKey: StoreKey.recentServers) ?? []
    }

    // MARK: - ScoutDrop

    func saveScoutDropNickname(_ name: String) {
        defaults.set(name, forKey: StoreKey.scoutDropNickname)
    }

    func loadScoutDropNickname() -> String {
        defaults.string(forKey: StoreKey.scoutDropNickname) ?? Host.current().localizedName ?? "Mac"
    }

    func saveScoutDropReceiveDirectory(_ url: URL) {
        defaults.set(url.path, forKey: StoreKey.scoutDropReceiveDirectory)
    }

    func loadScoutDropReceiveDirectory() -> URL {
        if let path = defaults.string(forKey: StoreKey.scoutDropReceiveDirectory) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/ScoutDrop")
    }

    // MARK: - ScoutDrop Device ID & Trusted Peers

    func loadScoutDropDeviceID() -> String {
        if let existing = defaults.string(forKey: StoreKey.scoutDropDeviceID) {
            return existing
        }
        let newID = UUID().uuidString
        defaults.set(newID, forKey: StoreKey.scoutDropDeviceID)
        return newID
    }

    func saveScoutDropTrustedPeer(deviceID: String, name: String) {
        var peers = loadScoutDropTrustedPeers()
        peers[deviceID] = name
        defaults.set(peers, forKey: StoreKey.scoutDropTrustedPeers)
    }

    func loadScoutDropTrustedPeers() -> [String: String] {
        defaults.dictionary(forKey: StoreKey.scoutDropTrustedPeers) as? [String: String] ?? [:]
    }

    func removeScoutDropTrustedPeer(deviceID: String) {
        var peers = loadScoutDropTrustedPeers()
        peers.removeValue(forKey: deviceID)
        defaults.set(peers, forKey: StoreKey.scoutDropTrustedPeers)
        removeScoutDropPeerKeyHash(deviceID: deviceID)
    }

    func isScoutDropPeerTrusted(deviceID: String) -> Bool {
        loadScoutDropTrustedPeers()[deviceID] != nil
    }

    func saveScoutDropPeerKeyHash(deviceID: String, keyHash: String) {
        var hashes = loadScoutDropPeerKeyHashes()
        hashes[deviceID] = keyHash
        defaults.set(hashes, forKey: StoreKey.scoutDropPeerKeyHashes)
    }

    func loadScoutDropPeerKeyHashes() -> [String: String] {
        defaults.dictionary(forKey: StoreKey.scoutDropPeerKeyHashes) as? [String: String] ?? [:]
    }

    func loadScoutDropPeerKeyHash(deviceID: String) -> String? {
        loadScoutDropPeerKeyHashes()[deviceID]
    }

    func removeScoutDropPeerKeyHash(deviceID: String) {
        var hashes = loadScoutDropPeerKeyHashes()
        hashes.removeValue(forKey: deviceID)
        defaults.set(hashes, forKey: StoreKey.scoutDropPeerKeyHashes)
    }

    // MARK: - Private Helpers

    private func workspaceFileURL(for id: UUID) -> URL {
        workspacesDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadDecodable<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private static func ensureDirectoryExists(at url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }

    private func logError(_ message: String) {
        #if DEBUG
            NSLog("[PersistenceService] %@", message)
        #endif
    }
}
