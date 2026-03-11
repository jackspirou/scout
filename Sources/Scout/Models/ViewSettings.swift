import Foundation

// MARK: - ViewMode

/// The visual mode for displaying directory contents.
enum ViewMode: String, Codable, CaseIterable, Sendable {
    case icon
    case list
    case column
    case gallery
}

// MARK: - SortField

/// Which file attribute to sort by.
enum SortField: String, Codable, CaseIterable, Sendable {
    case name
    case dateModified
    case dateCreated
    case size
    case kind
}

// MARK: - SortOrder

/// Ascending or descending sort direction.
enum SortOrder: String, Codable, CaseIterable, Sendable {
    case ascending
    case descending
}

// MARK: - GroupBy

/// Grouping criterion for file list display.
enum GroupBy: String, Codable, CaseIterable, Sendable {
    case none
    case kind
    case dateModified
    case dateCreated
    case size
    case tags
}

// MARK: - ViewSettings

/// Persisted settings for how a pane displays its contents.
struct ViewSettings: Codable, Equatable, Sendable {
    var viewMode: ViewMode
    var sortField: SortField
    var sortOrder: SortOrder
    var columnWidths: [String: CGFloat]
    var visibleColumns: [String]
    var showHiddenFiles: Bool
    var iconSize: Double
    var groupBy: GroupBy

    /// Sensible defaults matching Finder's initial state.
    static let `default` = ViewSettings(
        viewMode: .list,
        sortField: .name,
        sortOrder: .ascending,
        columnWidths: [
            "name": 300,
            "dateModified": 160,
            "size": 80,
            "kind": 120,
        ],
        visibleColumns: ["name", "dateModified", "size", "kind"],
        showHiddenFiles: false,
        iconSize: 64.0,
        groupBy: .none
    )

    init(
        viewMode: ViewMode = .list,
        sortField: SortField = .name,
        sortOrder: SortOrder = .ascending,
        columnWidths: [String: CGFloat] = [
            "name": 300,
            "dateModified": 160,
            "size": 80,
            "kind": 120,
        ],
        visibleColumns: [String] = ["name", "dateModified", "size", "kind"],
        showHiddenFiles: Bool = false,
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
