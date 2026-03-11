import Cocoa

// MARK: - BrowserTabState

/// Represents the runtime state of a single browser tab, including navigation history.
struct BrowserTabState {
    let id: UUID
    var url: URL
    var title: String
    var backStack: [URL]
    var forwardStack: [URL]

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.title = url.lastPathComponent
        self.backStack = []
        self.forwardStack = []
    }
}

// MARK: - BrowserPaneViewController

final class BrowserPaneViewController: NSViewController {

    // MARK: - Properties

    private var tabs: [BrowserTabState] = []
    private(set) var activeTabIndex: Int = 0
    private var isActive: Bool = false

    private let tabBar = NSStackView()
    private let pathBarView = PathBarView()
    private let fileListViewController = FileListViewController()
    private let statusBar = NSTextField(labelWithString: "0 items")

    /// The number of open tabs.
    var tabCount: Int { tabs.count }

    // MARK: - Constants

    private enum Layout {
        static let tabBarHeight: CGFloat = 28
        static let statusBarHeight: CGFloat = 22
        static let pathBarHeight: CGFloat = 30
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        configureTabBar()
        configurePathBar()
        configureFileList()
        configureStatusBar()
        layoutSubviews()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Open the home directory in the first tab by default
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        addTab(url: homeURL)

        pathBarView.delegate = self
        fileListViewController.delegate = self
    }

    // MARK: - Configuration

    private func configureTabBar() {
        tabBar.orientation = .horizontal
        tabBar.distribution = .fillProportionally
        tabBar.spacing = 1
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(tabBar)
    }

    private func configurePathBar() {
        pathBarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pathBarView)
    }

    private func configureFileList() {
        addChild(fileListViewController)
        fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fileListViewController.view)
    }

    private func configureStatusBar() {
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.font = NSFont.systemFont(ofSize: 11)
        statusBar.textColor = NSColor.secondaryLabelColor
        statusBar.isEditable = false
        statusBar.isBezeled = false
        statusBar.drawsBackground = false
        statusBar.alignment = .left
        statusBar.lineBreakMode = .byTruncatingTail
        view.addSubview(statusBar)
    }

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            // Tab bar at the very top
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Layout.tabBarHeight),

            // Path bar below tab bar
            pathBarView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            pathBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pathBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pathBarView.heightAnchor.constraint(equalToConstant: Layout.pathBarHeight),

            // File list fills the middle
            fileListViewController.view.topAnchor.constraint(equalTo: pathBarView.bottomAnchor),
            fileListViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fileListViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fileListViewController.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Status bar at the bottom
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Layout.statusBarHeight),
        ])
    }

    // MARK: - Public API

    /// Navigate the current tab to the given URL.
    func navigateTo(url: URL) {
        guard !tabs.isEmpty else { return }

        var tab = tabs[activeTabIndex]
        tab.backStack.append(tab.url)
        tab.forwardStack.removeAll()
        tab.url = url
        tab.title = url.lastPathComponent
        tabs[activeTabIndex] = tab

        reloadCurrentTab()
    }

    /// Navigate back in the current tab's history.
    func goBack() {
        guard !tabs.isEmpty else { return }
        var tab = tabs[activeTabIndex]
        guard let previousURL = tab.backStack.popLast() else { return }

        tab.forwardStack.append(tab.url)
        tab.url = previousURL
        tab.title = previousURL.lastPathComponent
        tabs[activeTabIndex] = tab

        reloadCurrentTab()
    }

    /// Navigate forward in the current tab's history.
    func goForward() {
        guard !tabs.isEmpty else { return }
        var tab = tabs[activeTabIndex]
        guard let nextURL = tab.forwardStack.popLast() else { return }

        tab.backStack.append(tab.url)
        tab.url = nextURL
        tab.title = nextURL.lastPathComponent
        tabs[activeTabIndex] = tab

        reloadCurrentTab()
    }

    /// Navigate to the parent directory.
    func goToParent() {
        guard !tabs.isEmpty else { return }
        let parentURL = tabs[activeTabIndex].url.deletingLastPathComponent()
        navigateTo(url: parentURL)
    }

    /// Add a new tab pointing to the given URL and switch to it.
    func addTab(url: URL) {
        let tab = BrowserTabState(url: url)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        rebuildTabBar()
        reloadCurrentTab()
    }

    /// Close the tab at the specified index.
    func closeTab(at index: Int) {
        guard tabs.indices.contains(index), tabs.count > 1 else { return }

        tabs.remove(at: index)

        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }

        rebuildTabBar()
        reloadCurrentTab()
    }

    /// Returns the URL of the currently active tab.
    func currentURL() -> URL {
        guard tabs.indices.contains(activeTabIndex) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return tabs[activeTabIndex].url
    }

    /// Sets the active/focused visual state of this pane.
    func setActive(_ active: Bool) {
        isActive = active
        view.wantsLayer = true
        if active {
            view.layer?.borderWidth = 2
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            view.layer?.borderWidth = 0
            view.layer?.borderColor = nil
        }
    }

    // MARK: - Keyboard Navigation

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 36: // Return/Enter - open selected item
            fileListViewController.openSelectedItem()
        case 126 where flags.contains(.command): // Cmd+Up - parent directory
            goToParent()
        case 51: // Backspace/Delete - go back
            goBack()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Tab Bar

    private func rebuildTabBar() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, tab) in tabs.enumerated() {
            let button = makeTabButton(title: tab.title, index: index, isSelected: index == activeTabIndex)
            tabBar.addArrangedSubview(button)
        }
    }

    private func makeTabButton(title: String, index: Int, isSelected: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
        container.layer?.cornerRadius = 4

        let button = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
        button.tag = index
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!,
            target: self,
            action: #selector(closeTabClicked(_:))
        )
        closeButton.tag = index
        closeButton.isBordered = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = tabs.count <= 1
        container.addSubview(closeButton)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            container.heightAnchor.constraint(equalToConstant: Layout.tabBarHeight - 4),
        ])

        return container
    }

    @objc private func tabClicked(_ sender: NSButton) {
        let index = sender.tag
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
        rebuildTabBar()
        reloadCurrentTab()
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        closeTab(at: sender.tag)
    }

    // MARK: - Reload

    private func reloadCurrentTab() {
        guard tabs.indices.contains(activeTabIndex) else { return }
        let url = tabs[activeTabIndex].url
        pathBarView.update(with: url)
        fileListViewController.loadDirectory(at: url)
    }

    private func updateStatusBar(itemCount: Int, selectedCount: Int) {
        if selectedCount > 0 {
            statusBar.stringValue = "\(itemCount) items, \(selectedCount) selected"
        } else {
            statusBar.stringValue = "\(itemCount) items"
        }
    }
}

// MARK: - PathBarDelegate

extension BrowserPaneViewController: PathBarDelegate {

    func pathBar(_ pathBar: PathBarView, didNavigateTo url: URL) {
        navigateTo(url: url)
    }

    func pathBar(_ pathBar: PathBarView, didEditPath url: URL) {
        navigateTo(url: url)
    }
}

// MARK: - FileListViewDelegate

extension BrowserPaneViewController: FileListViewDelegate {

    func fileListView(_ controller: FileListViewController, didSelectItems items: [FileItem]) {
        updateStatusBar(itemCount: controller.itemCount, selectedCount: items.count)
    }

    func fileListView(_ controller: FileListViewController, didOpenItem item: FileItem) {
        if item.isDirectory {
            navigateTo(url: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func fileListView(_ controller: FileListViewController, didRequestContextMenu items: [FileItem]) {
        // Context menu is built and displayed by FileListViewController itself
    }

    func fileListViewDidFinishLoading(_ controller: FileListViewController, itemCount: Int) {
        updateStatusBar(itemCount: itemCount, selectedCount: 0)
    }
}
