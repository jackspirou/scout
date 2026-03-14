import Foundation

/// Protocol for persistence operations, enabling mock implementations for testing.
protocol PersistenceServiceProtocol {
    func saveViewSettings(for directory: URL, settings: ViewSettings)
    func loadViewSettings(for directory: URL) -> ViewSettings?
    func saveWorkspace(_ workspace: Workspace) async
    func loadWorkspace(id: UUID) async -> Workspace?
    func listWorkspaces() async -> [Workspace]
    func deleteWorkspace(id: UUID) async
    func saveLastSession(_ windowState: WindowState) async
    func loadLastSession() async -> WindowState?
    func saveRecentLocations(_ urls: [URL])
    func loadRecentLocations() -> [URL]
    func saveIconStyle(_ style: IconStyle)
    func loadIconStyle() -> IconStyle
    func saveShowHiddenFiles(_ show: Bool)
    func loadShowHiddenFiles() -> Bool

    // MARK: - Sidebar Favorites

    func saveSidebarFavorites(_ urls: [URL])
    func loadSidebarFavorites() -> [URL]

    // MARK: - Recent Servers
    func saveRecentServers(_ servers: [String])
    func loadRecentServers() -> [String]
}
