import Foundation

// MARK: - PaneState

/// Snapshot of a single pane's navigation and display state.
struct PaneState: Codable, Equatable {
    var path: URL
    var viewSettings: ViewSettings
    var scrollPosition: CGFloat
    var selectedItems: [URL]

    static func `default`(path: URL? = nil) -> PaneState {
        PaneState(
            path: path ?? FileManager.default.homeDirectoryForCurrentUser,
            viewSettings: .default,
            scrollPosition: 0,
            selectedItems: []
        )
    }
}

// MARK: - TabState

/// A single tab within a pane, including its navigation state and metadata.
struct TabState: Codable, Equatable {
    var paneState: PaneState
    var title: String
    var isPinned: Bool

    static func `default`(path: URL? = nil) -> TabState {
        let resolvedPath = path ?? FileManager.default.homeDirectoryForCurrentUser
        return TabState(
            paneState: .default(path: resolvedPath),
            title: resolvedPath.lastPathComponent,
            isPinned: false
        )
    }
}

// MARK: - WindowFrame

/// Serializable representation of a window's on-screen frame.
struct WindowFrame: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

// MARK: - WindowState

/// The full state of a single window, including tabs for both panes.
struct WindowState: Codable, Equatable {
    var leftTabs: [TabState]
    var rightTabs: [TabState]
    var activeLeftTab: Int
    var activeRightTab: Int
    var isDualPane: Bool
    var showPreview: Bool
    var windowFrame: WindowFrame?
    var sidebarWidth: Double

    static let `default` = WindowState(
        leftTabs: [.default()],
        rightTabs: [.default()],
        activeLeftTab: 0,
        activeRightTab: 0,
        isDualPane: false,
        showPreview: false,
        windowFrame: nil,
        sidebarWidth: 220.0
    )

    init(
        leftTabs: [TabState] = [.default()],
        rightTabs: [TabState] = [.default()],
        activeLeftTab: Int = 0,
        activeRightTab: Int = 0,
        isDualPane: Bool = false,
        showPreview: Bool = false,
        windowFrame: WindowFrame? = nil,
        sidebarWidth: Double = 220.0
    ) {
        self.leftTabs = leftTabs
        self.rightTabs = rightTabs
        self.activeLeftTab = activeLeftTab
        self.activeRightTab = activeRightTab
        self.isDualPane = isDualPane
        self.showPreview = showPreview
        self.windowFrame = windowFrame
        self.sidebarWidth = sidebarWidth
    }
}

// MARK: - Workspace

/// A named, persistable workspace that captures the complete window layout.
struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var windowState: WindowState
    var rootPaths: [URL]
    var pinnedPaths: [URL]
    let createdAt: Date
    var lastUsedAt: Date

    /// Alias used by PersistenceService for sort ordering.
    var updatedAt: Date {
        get { lastUsedAt }
        set { lastUsedAt = newValue }
    }

    /// Creates a fresh workspace with default state.
    static func createDefault(name: String = "Default") -> Workspace {
        let now = Date()
        return Workspace(
            id: UUID(),
            name: name,
            windowState: .default,
            rootPaths: [],
            pinnedPaths: [],
            createdAt: now,
            lastUsedAt: now
        )
    }

    init(
        id: UUID = UUID(),
        name: String,
        windowState: WindowState = .default,
        rootPaths: [URL] = [],
        pinnedPaths: [URL] = [],
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.windowState = windowState
        self.rootPaths = rootPaths
        self.pinnedPaths = pinnedPaths
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}
