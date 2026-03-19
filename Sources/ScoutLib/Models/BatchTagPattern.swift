import Foundation

// MARK: - BatchTagPattern

/// Defines a pattern for batch tagging operations.
enum BatchTagPattern {
    case add(tags: [String])
    case remove(tags: [String])
    case set(tags: [String])
}
