import Cocoa

// MARK: - SearchBarScope

/// Defines the scope of a file search operation in the search bar UI.
enum SearchBarScope: Int, CaseIterable {
    case currentFolder = 0
    case subfolders = 1
    case fullDisk = 2

    var title: String {
        switch self {
        case .currentFolder: return "Current Folder"
        case .subfolders: return "Subfolders"
        case .fullDisk: return "Full Disk"
        }
    }
}

// MARK: - SearchBarFilter

/// Represents a single filter token applied to search results in the search bar UI.
struct SearchBarFilter: Hashable {
    enum FilterType: String, CaseIterable {
        case kind
        case size
        case dateModified
        case tag
    }

    let type: FilterType
    let value: String
    let displayTitle: String
}

// MARK: - SearchBarDelegate

protocol SearchBarDelegate: AnyObject {
    /// Called when the search query or filters change and new results should be displayed.
    func searchBar(_ controller: SearchBarViewController, didUpdateQuery query: String, scope: SearchBarScope, filters: [SearchBarFilter])
    /// Called when the user dismisses the search bar.
    func searchBarDidDismiss(_ controller: SearchBarViewController)
}

// MARK: - SearchBarViewController

final class SearchBarViewController: NSViewController {

    // MARK: - Properties

    weak var delegate: SearchBarDelegate?

    private let searchField = NSSearchField()
    private let scopeSelector = NSSegmentedControl()
    private let filterTokenStack = NSStackView()
    private let filterMenuButton = NSPopUpButton()

    private var activeFilters: [SearchBarFilter] = []
    private var currentScope: SearchBarScope = .currentFolder

    private var debounceTimer: Timer?

    // MARK: - Constants

    private enum Layout {
        static let searchFieldHeight: CGFloat = 28
        static let filterBarHeight: CGFloat = 26
        static let padding: CGFloat = 8
        static let debounceInterval: TimeInterval = 0.2
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        configureSearchField()
        configureScopeSelector()
        configureFilterTokenStack()
        configureFilterMenuButton()
        layoutSubviews()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    // MARK: - Configuration

    private func configureSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search files..."
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.focusRingType = .none
        view.addSubview(searchField)
    }

    private func configureScopeSelector() {
        scopeSelector.translatesAutoresizingMaskIntoConstraints = false
        scopeSelector.segmentStyle = .capsule
        scopeSelector.trackingMode = .selectOne

        for (index, scope) in SearchBarScope.allCases.enumerated() {
            scopeSelector.segmentCount = SearchBarScope.allCases.count
            scopeSelector.setLabel(scope.title, forSegment: index)
            scopeSelector.setWidth(0, forSegment: index) // Auto-size
        }

        scopeSelector.selectedSegment = 0
        scopeSelector.target = self
        scopeSelector.action = #selector(scopeChanged(_:))
        view.addSubview(scopeSelector)
    }

    private func configureFilterTokenStack() {
        filterTokenStack.translatesAutoresizingMaskIntoConstraints = false
        filterTokenStack.orientation = .horizontal
        filterTokenStack.spacing = 4
        filterTokenStack.alignment = .centerY
        filterTokenStack.distribution = .gravityAreas
        view.addSubview(filterTokenStack)
    }

    private func configureFilterMenuButton() {
        filterMenuButton.translatesAutoresizingMaskIntoConstraints = false
        filterMenuButton.isBordered = false
        filterMenuButton.font = NSFont.systemFont(ofSize: 11)
        filterMenuButton.pullsDown = true

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Add Filter", action: nil, keyEquivalent: "")
        titleItem.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add Filter")
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Kind filter
        let kindItem = NSMenuItem(title: "Kind", action: nil, keyEquivalent: "")
        let kindSubmenu = NSMenu()
        for kind in ["Document", "Image", "Video", "Audio", "Archive", "Application", "Folder"] {
            let item = NSMenuItem(title: kind, action: #selector(addKindFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
            kindSubmenu.addItem(item)
        }
        kindItem.submenu = kindSubmenu
        menu.addItem(kindItem)

        // Size filter
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeSubmenu = NSMenu()
        for (label, value) in [("< 1 MB", "lt1mb"), ("1-10 MB", "1to10mb"), ("10-100 MB", "10to100mb"), ("> 100 MB", "gt100mb")] {
            let item = NSMenuItem(title: label, action: #selector(addSizeFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            sizeSubmenu.addItem(item)
        }
        sizeItem.submenu = sizeSubmenu
        menu.addItem(sizeItem)

        // Date modified filter
        let dateItem = NSMenuItem(title: "Date Modified", action: nil, keyEquivalent: "")
        let dateSubmenu = NSMenu()
        for (label, value) in [("Today", "today"), ("Last 7 days", "week"), ("Last 30 days", "month"), ("Last year", "year")] {
            let item = NSMenuItem(title: label, action: #selector(addDateFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            dateSubmenu.addItem(item)
        }
        dateItem.submenu = dateSubmenu
        menu.addItem(dateItem)

        // Tag filter
        let tagItem = NSMenuItem(title: "Tag", action: nil, keyEquivalent: "")
        let tagSubmenu = NSMenu()
        for tag in ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"] {
            let item = NSMenuItem(title: tag, action: #selector(addTagFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tag
            tagSubmenu.addItem(item)
        }
        tagItem.submenu = tagSubmenu
        menu.addItem(tagItem)

        filterMenuButton.menu = menu
        view.addSubview(filterMenuButton)
    }

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            // Search field at top
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.padding),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.padding),
            searchField.heightAnchor.constraint(equalToConstant: Layout.searchFieldHeight),

            // Scope selector to the right of search field
            scopeSelector.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            scopeSelector.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: Layout.padding),
            scopeSelector.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.padding),

            // Filter token area below search field
            filterTokenStack.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            filterTokenStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.padding),
            filterTokenStack.heightAnchor.constraint(equalToConstant: Layout.filterBarHeight),

            // Add filter button at the end of the filter stack
            filterMenuButton.centerYAnchor.constraint(equalTo: filterTokenStack.centerYAnchor),
            filterMenuButton.leadingAnchor.constraint(equalTo: filterTokenStack.trailingAnchor, constant: 4),
            filterMenuButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Layout.padding),

            // Bottom constraint
            filterTokenStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
    }

    // MARK: - Public API

    /// Activates the search bar and focuses the search field.
    func activate() {
        view.window?.makeFirstResponder(searchField)
    }

    /// Clears the search and resets all filters.
    func reset() {
        searchField.stringValue = ""
        activeFilters.removeAll()
        currentScope = .currentFolder
        scopeSelector.selectedSegment = 0
        rebuildFilterTokens()
    }

    // MARK: - Scope

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        guard let scope = SearchBarScope(rawValue: sender.selectedSegment) else { return }
        currentScope = scope
        notifyDelegate()
    }

    // MARK: - Filter Actions

    @objc private func addKindFilter(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        let filter = SearchBarFilter(type: .kind, value: kind.lowercased(), displayTitle: "Kind: \(kind)")
        addFilter(filter)
    }

    @objc private func addSizeFilter(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let filter = SearchBarFilter(type: .size, value: value, displayTitle: "Size: \(sender.title)")
        addFilter(filter)
    }

    @objc private func addDateFilter(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let filter = SearchBarFilter(type: .dateModified, value: value, displayTitle: "Modified: \(sender.title)")
        addFilter(filter)
    }

    @objc private func addTagFilter(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let filter = SearchBarFilter(type: .tag, value: tag.lowercased(), displayTitle: "Tag: \(tag)")
        addFilter(filter)
    }

    private func addFilter(_ filter: SearchBarFilter) {
        // Remove existing filter of same type to replace it
        activeFilters.removeAll { $0.type == filter.type }
        activeFilters.append(filter)
        rebuildFilterTokens()
        notifyDelegate()
    }

    private func removeFilter(_ filter: SearchBarFilter) {
        activeFilters.removeAll { $0 == filter }
        rebuildFilterTokens()
        notifyDelegate()
    }

    // MARK: - Filter Token UI

    private func rebuildFilterTokens() {
        filterTokenStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for filter in activeFilters {
            let token = makeFilterToken(for: filter)
            filterTokenStack.addArrangedSubview(token)
        }
    }

    private func makeFilterToken(for filter: SearchBarFilter) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        container.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: filter.displayTitle)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .controlAccentColor
        container.addSubview(label)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove filter")!,
            target: self,
            action: #selector(removeFilterToken(_:))
        )
        closeButton.isBordered = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tag = activeFilters.firstIndex(of: filter) ?? 0
        container.addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),

            container.heightAnchor.constraint(equalToConstant: 22),
        ])

        return container
    }

    @objc private func removeFilterToken(_ sender: NSButton) {
        let index = sender.tag
        guard activeFilters.indices.contains(index) else { return }
        let filter = activeFilters[index]
        removeFilter(filter)
    }

    // MARK: - Delegate Notification

    private func notifyDelegate() {
        delegate?.searchBar(self, didUpdateQuery: searchField.stringValue, scope: currentScope, filters: activeFilters)
    }
}

// MARK: - NSSearchFieldDelegate

extension SearchBarViewController: NSSearchFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        // Debounce the search query
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: Layout.debounceInterval, repeats: false) { [weak self] _ in
            self?.notifyDelegate()
        }
    }

    func searchFieldDidStartSearching(_ sender: NSSearchField) {
        notifyDelegate()
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty {
            delegate?.searchBarDidDismiss(self)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            reset()
            delegate?.searchBarDidDismiss(self)
            return true
        }
        return false
    }
}
