import Foundation

// MARK: - SearchResultGroup

/// Groups search results by parent directory for display with section headers.
struct SearchResultGroup {
    let directory: URL
    var items: [FileItem]
    var isCollapsed: Bool = false

    var directoryName: String {
        directory.lastPathComponent
    }

    var directoryPath: String {
        directory.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }
}

// MARK: - SearchDisplayRow

/// A row in the grouped search results table — either a group header or a file item.
enum SearchDisplayRow {
    case header(groupIndex: Int)
    case item(FileItem)

    var fileItem: FileItem? {
        switch self {
        case .header: return nil
        case let .item(item): return item
        }
    }

    var isHeader: Bool {
        switch self {
        case .header: return true
        case .item: return false
        }
    }
}

// MARK: - Grouping

extension SearchResultGroup {
    /// Groups a flat list of FileItems by parent directory.
    static func group(_ items: [FileItem]) -> [SearchResultGroup] {
        var groupMap: [URL: [FileItem]] = [:]
        var groupOrder: [URL] = []

        for item in items {
            let parent = item.url.deletingLastPathComponent()
            if groupMap[parent] == nil {
                groupOrder.append(parent)
            }
            groupMap[parent, default: []].append(item)
        }

        return groupOrder.map { url in
            SearchResultGroup(directory: url, items: groupMap[url] ?? [])
        }
    }

    /// Flattens groups into display rows, respecting collapsed state.
    static func flatten(_ groups: [SearchResultGroup]) -> [SearchDisplayRow] {
        var rows: [SearchDisplayRow] = []
        for (index, group) in groups.enumerated() {
            rows.append(.header(groupIndex: index))
            if !group.isCollapsed {
                for item in group.items {
                    rows.append(.item(item))
                }
            }
        }
        return rows
    }
}
