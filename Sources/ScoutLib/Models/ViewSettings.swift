import Foundation

// MARK: - ViewMode

/// The visual mode for displaying directory contents.
enum ViewMode: String, Codable, CaseIterable {
    case icon
    case list
    case column
    case gallery
}

// MARK: - SortField

/// Which file attribute to sort by.
enum SortField: String, Codable, CaseIterable {
    case name
    case dateModified
    case dateCreated
    case dateLastOpened
    case dateAdded
    case size
    case kind
    case tags
}

// MARK: - SortOrder

/// Ascending or descending sort direction.
enum SortOrder: String, Codable, CaseIterable {
    case ascending
    case descending
}

// MARK: - GroupBy

/// Grouping criterion for file list display.
enum GroupBy: String, Codable, CaseIterable {
    case none
    case kind
    case dateModified
    case dateCreated
    case size
    case tags
}

// MARK: - IconStyle

/// Controls whether file icons are native macOS icons or flat SF Symbols.
enum IconStyle: String, CaseIterable {
    case system // Native macOS icons (default)
    case flat // SF Symbol icons
}

// MARK: - ViewSettings

/// Persisted settings for how a pane displays its contents.
struct ViewSettings: Codable, Equatable {
    var viewMode: ViewMode
    var sortField: SortField
    var sortOrder: SortOrder
    var columnWidths: [SortField: CGFloat]
    var visibleColumns: [SortField]
    var showHiddenFiles: Bool
    var iconSize: Double
    var groupBy: GroupBy

    /// Sensible defaults matching Finder's initial state.
    static let `default` = ViewSettings(
        viewMode: .list,
        sortField: .name,
        sortOrder: .ascending,
        columnWidths: [
            .name: 300,
            .dateModified: 160,
            .dateCreated: 160,
            .dateLastOpened: 160,
            .dateAdded: 160,
            .size: 80,
            .kind: 120,
            .tags: 120,
        ],
        visibleColumns: [.name, .dateModified, .size, .kind],
        showHiddenFiles: true,
        iconSize: 64.0,
        groupBy: .none
    )

    init(
        viewMode: ViewMode = .list,
        sortField: SortField = .name,
        sortOrder: SortOrder = .ascending,
        columnWidths: [SortField: CGFloat] = [
            .name: 300,
            .dateModified: 160,
            .dateCreated: 160,
            .dateLastOpened: 160,
            .dateAdded: 160,
            .size: 80,
            .kind: 120,
            .tags: 120,
        ],
        visibleColumns: [SortField] = [.name, .dateModified, .size, .kind],
        showHiddenFiles: Bool = true,
        iconSize: Double = 64.0,
        groupBy: GroupBy = .none
    ) {
        self.viewMode = viewMode
        self.sortField = sortField
        self.sortOrder = sortOrder
        self.columnWidths = columnWidths
        self.visibleColumns = visibleColumns
        self.showHiddenFiles = showHiddenFiles
        self.iconSize = iconSize
        self.groupBy = groupBy
    }
}
