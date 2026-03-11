import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - URL Extensions

extension URL {
    /// Returns `true` if this URL points to a directory.
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Returns the file size in bytes, or 0 for directories and errors.
    var fileSize: Int64 {
        let values = try? resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey])
        return Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
    }

    /// Returns the content modification date, or `.distantPast` if unavailable.
    var modificationDate: Date {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    /// Returns the creation date, or `.distantPast` if unavailable.
    var creationDate: Date {
        (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    /// Returns `true` if this file is hidden (dot-prefixed or has the hidden flag).
    var isHidden: Bool {
        (try? resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
    }

    /// Returns the Finder tags applied to this file.
    var fileTags: [String] {
        (try? resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }
}

// MARK: - NSImage Extension

extension NSImage {
    /// Returns the system icon for the file at the given URL.
    /// Uses NSWorkspace to get the icon that Finder would display.
    static func systemIcon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Returns the system icon for a given UTType identifier string.
    static func systemIcon(forType typeIdentifier: String) -> NSImage {
        if let utType = UTType(typeIdentifier) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .item)
    }
}

// MARK: - Int64 Extension

extension Int64 {
    /// Formats byte count into a human-readable string (e.g., "4.2 MB").
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

// MARK: - Date Extension

extension Date {
    /// Returns a relative-formatted string.
    /// - "Just now" for dates within the last minute
    /// - "Today" / "Yesterday" for recent dates
    /// - "Mar 5" for dates within the current year
    /// - "Mar 5, 2023" for older dates
    var relativeFormatted: String {
        let calendar = Calendar.current
        let now = Date()

        let secondsAgo = now.timeIntervalSince(self)

        if secondsAgo < 60 {
            return "Just now"
        }

        if calendar.isDateInToday(self) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "Today, \(formatter.string(from: self))"
        }

        if calendar.isDateInYesterday(self) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "Yesterday, \(formatter.string(from: self))"
        }

        let currentYear = calendar.component(.year, from: now)
        let dateYear = calendar.component(.year, from: self)

        if currentYear == dateYear {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: self)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: self)
    }
}

// MARK: - NSEvent.ModifierFlags Extension

extension NSEvent.ModifierFlags {
    /// Returns a readable string representation of the modifier flags.
    /// Uses standard macOS symbols.
    var readableString: String {
        var parts: [String] = []

        if contains(.control) {
            parts.append("\u{2303}") // Control symbol
        }
        if contains(.option) {
            parts.append("\u{2325}") // Option symbol
        }
        if contains(.shift) {
            parts.append("\u{21E7}") // Shift symbol
        }
        if contains(.command) {
            parts.append("\u{2318}") // Command symbol
        }
        if contains(.function) {
            parts.append("Fn")
        }

        return parts.joined()
    }

    /// Returns a verbose string representation using words.
    var verboseString: String {
        var parts: [String] = []

        if contains(.control) {
            parts.append("Control")
        }
        if contains(.option) {
            parts.append("Option")
        }
        if contains(.shift) {
            parts.append("Shift")
        }
        if contains(.command) {
            parts.append("Command")
        }
        if contains(.function) {
            parts.append("Function")
        }

        return parts.joined(separator: " + ")
    }
}

// MARK: - String Extension

extension String {
    /// Performs fuzzy matching of a query against this string.
    /// Returns `true` if all characters of the query appear in order within this string.
    func fuzzyMatch(query: String) -> Bool {
        fuzzyMatchScore(query: query) != nil
    }

    /// Returns a fuzzy match score, or `nil` if no match.
    /// Higher scores indicate better matches.
    ///
    /// Scoring rules:
    /// - +1 per matched character
    /// - +5 for consecutive character matches
    /// - +10 for matching at the start of the string
    /// - +8 for matching at word boundaries (after space, dot, dash, underscore)
    /// - +3 for matching uppercase characters (camelCase bonus)
    /// - +15 for prefix match
    /// - Penalty for length difference
    func fuzzyMatchScore(query: String) -> Int? {
        guard !query.isEmpty else { return nil }

        let normalizedQuery = query.lowercased()
        let normalizedTarget = lowercased()

        var score = 0
        var queryIndex = normalizedQuery.startIndex
        var targetIndex = normalizedTarget.startIndex
        var previousMatchIndex: String.Index?
        var matchCount = 0

        while queryIndex < normalizedQuery.endIndex, targetIndex < normalizedTarget.endIndex {
            let queryChar = normalizedQuery[queryIndex]
            let targetChar = normalizedTarget[targetIndex]

            if queryChar == targetChar {
                matchCount += 1
                score += 1

                // Bonus for consecutive matches.
                if let prevIdx = previousMatchIndex,
                   normalizedTarget.index(after: prevIdx) == targetIndex
                {
                    score += 5
                }

                // Bonus for matching at string start.
                if targetIndex == normalizedTarget.startIndex {
                    score += 10
                } else {
                    // Bonus for word boundary matches.
                    let prevTargetIndex = normalizedTarget.index(before: targetIndex)
                    let prevChar = normalizedTarget[prevTargetIndex]
                    if prevChar == " " || prevChar == "." || prevChar == "-" || prevChar == "_" {
                        score += 8
                    }
                }

                // Bonus for uppercase characters in original string (camelCase).
                if targetIndex < endIndex {
                    let originalChar = self[targetIndex]
                    if originalChar.isUppercase {
                        score += 3
                    }
                }

                previousMatchIndex = targetIndex
                queryIndex = normalizedQuery.index(after: queryIndex)
            }

            targetIndex = normalizedTarget.index(after: targetIndex)
        }

        // All query characters must be matched.
        guard queryIndex == normalizedQuery.endIndex else { return nil }

        // Bonus for prefix match.
        if normalizedTarget.hasPrefix(normalizedQuery) {
            score += 15
        }

        // Penalty for length difference.
        let lengthDiff = normalizedTarget.count - normalizedQuery.count
        score -= lengthDiff

        return score
    }
}
