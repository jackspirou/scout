import Foundation

// MARK: - BrowserTabState

/// Represents the runtime state of a single browser tab, including navigation history.
struct BrowserTabState {
    let id: UUID
    var url: URL
    var title: String
    var backStack: [URL]
    var forwardStack: [URL]

    init(url: URL) {
        id = UUID()
        self.url = url
        title = url.lastPathComponent
        backStack = []
        forwardStack = []
    }
}
