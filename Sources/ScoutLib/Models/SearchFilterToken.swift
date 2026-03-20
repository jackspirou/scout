import Foundation
import UniformTypeIdentifiers

// MARK: - SearchFilterToken

/// Parses structured filter tokens (e.g. `kind:pdf`, `size:>10mb`) from a search query string.
enum SearchFilterToken {
    /// Result of parsing a query string: the remaining plain text and extracted filters.
    struct ParseResult {
        let textQuery: String
        let filters: [SearchFilter]
        let displayTokens: [DisplayToken]
    }

    /// A token for display in the pill bar.
    struct DisplayToken {
        let label: String
        let filter: SearchFilter
        let category: Category
    }

    enum Category {
        case kind
        case size
        case modified
        case tag
    }

    // MARK: - Public API

    /// Parses a query string, extracting structured filter tokens and returning the remaining text.
    /// Repeated `kind:` tokens are merged into a single OR filter (e.g. `kind:pdf kind:image`).
    static func parse(_ query: String) -> ParseResult {
        var remaining: [String] = []
        var filters: [SearchFilter] = []
        var displayTokens: [DisplayToken] = []

        // Collect kind values separately for merging
        var kindUTTypes: [String] = []
        var kindLabels: [String] = []

        let tokens = tokenize(query)

        for token in tokens {
            if let colonIndex = token.firstIndex(of: ":") {
                let key = String(token[token.startIndex ..< colonIndex]).lowercased()
                let rawValue = String(token[token.index(after: colonIndex)...])
                let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                if key == "kind" {
                    // Collect kind values for merging
                    let names = value.split(separator: ",").map {
                        String($0).lowercased().trimmingCharacters(in: .whitespaces)
                    }
                    let uttypes = names.compactMap { kindMap[$0] }
                    if !uttypes.isEmpty {
                        kindUTTypes.append(contentsOf: uttypes)
                        kindLabels.append(contentsOf: names.filter { kindMap[$0] != nil })
                    } else {
                        remaining.append(token)
                    }
                } else if let parsed = parseFilter(key: key, value: value) {
                    filters.append(parsed.filter)
                    displayTokens.append(parsed)
                } else {
                    remaining.append(token)
                }
            } else {
                remaining.append(token)
            }
        }

        // Merge all kind values into a single OR filter
        if !kindUTTypes.isEmpty {
            let label = "kind:\(kindLabels.joined(separator: ","))"
            filters.append(.kind(kindUTTypes))
            displayTokens.append(DisplayToken(label: label, filter: .kind(kindUTTypes), category: .kind))
        }

        return ParseResult(
            textQuery: remaining.joined(separator: " "),
            filters: filters,
            displayTokens: displayTokens
        )
    }

    // MARK: - Tokenizer

    /// Splits the query respecting quoted values (e.g. `tag:"my tag"`).
    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in query {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == " ", !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    // MARK: - Filter Parsing

    private static func parseFilter(key: String, value: String) -> DisplayToken? {
        guard !value.isEmpty else { return nil }

        switch key {
        case "kind":
            return parseKindFilter(value)
        case "size":
            return parseSizeFilter(value)
        case "modified":
            return parseModifiedFilter(value)
        case "tag":
            return DisplayToken(
                label: "tag:\(value)",
                filter: .hasTag(value),
                category: .tag
            )
        default:
            return nil
        }
    }

    private static let kindMap: [String: String] = [
        "pdf": "com.adobe.pdf",
        "image": "public.image",
        "video": "public.movie",
        "audio": "public.audio",
        "text": "public.text",
        "archive": "public.archive",
        "folder": "public.folder",
    ]

    private static func parseKindFilter(_ value: String) -> DisplayToken? {
        // Support comma-separated values: kind:pdf,image
        let names = value.split(separator: ",").map { String($0).lowercased().trimmingCharacters(in: .whitespaces) }
        let uttypes = names.compactMap { kindMap[$0] }
        guard !uttypes.isEmpty else { return nil }

        return DisplayToken(
            label: "kind:\(value)",
            filter: .kind(uttypes),
            category: .kind
        )
    }

    private static func parseSizeFilter(_ value: String) -> DisplayToken? {
        // Parse patterns like ">10mb", "<500kb", ">1gb"
        guard let first = value.first, first == ">" || first == "<" else { return nil }

        let isGreaterThan = first == ">"
        let sizeStr = String(value.dropFirst()).lowercased()

        guard let bytes = parseByteSize(sizeStr) else { return nil }

        let filter: SearchFilter = isGreaterThan
            ? .sizeGreaterThan(bytes)
            : .sizeLessThan(bytes)

        return DisplayToken(
            label: "size:\(value)",
            filter: filter,
            category: .size
        )
    }

    private static func parseByteSize(_ str: String) -> Int64? {
        let multipliers: [(suffix: String, multiplier: Int64)] = [
            ("gb", 1_073_741_824),
            ("mb", 1_048_576),
            ("kb", 1024),
            ("b", 1),
        ]

        for (suffix, multiplier) in multipliers {
            if str.hasSuffix(suffix) {
                let numStr = String(str.dropLast(suffix.count))
                guard let num = Double(numStr) else { return nil }
                return Int64(num * Double(multiplier))
            }
        }

        // No suffix — treat as bytes
        return Int64(str)
    }

    private static func parseModifiedFilter(_ value: String) -> DisplayToken? {
        let calendar = Calendar.current
        let now = Date()
        let date: Date?

        switch value.lowercased() {
        case "today":
            date = calendar.startOfDay(for: now)
        case "yesterday":
            date = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case "thisweek":
            date = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
        case "thismonth":
            date = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        default:
            // Try ISO date: 2025-01-01
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            date = formatter.date(from: value)
        }

        guard let date else { return nil }

        return DisplayToken(
            label: "modified:\(value)",
            filter: .modifiedAfter(date),
            category: .modified
        )
    }
}

// MARK: - FileItem filter matching

extension SearchFilter {
    /// Tests whether a FileItem matches this filter.
    func matches(_ item: FileItem) -> Bool {
        switch self {
        case let .kind(uttypeIdentifiers):
            guard let contentType = item.contentType,
                  let itemType = UTType(contentType)
            else { return false }
            return uttypeIdentifiers.contains { id in
                guard let filterType = UTType(id) else { return false }
                return itemType.conforms(to: filterType)
            }
        case let .sizeGreaterThan(bytes):
            guard let size = item.size else { return false }
            return size > bytes
        case let .sizeLessThan(bytes):
            guard let size = item.size else { return false }
            return size < bytes
        case let .modifiedAfter(date):
            guard let modified = item.modificationDate else { return false }
            return modified >= date
        case let .modifiedBefore(date):
            guard let modified = item.modificationDate else { return false }
            return modified <= date
        case let .hasTag(tag):
            return item.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }
}
