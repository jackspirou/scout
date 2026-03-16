import Foundation

// MARK: - BatchRenamePattern

/// Defines a pattern for batch renaming operations.
enum BatchRenamePattern {
    case regex(pattern: String, replacement: String)
    case sequential(prefix: String, startNumber: Int, zeroPadding: Int, suffix: String)
    case findReplace(find: String, replace: String, caseSensitive: Bool)
    case datePrefix(format: String)
}
