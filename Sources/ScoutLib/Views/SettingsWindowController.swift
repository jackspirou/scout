import AppKit

// MARK: - SettingsWindowController

/// A Cmd+, Settings window with General and About tabs.
final class SettingsWindowController: NSWindowController {
    // MARK: - Initialization

    convenience init() {
        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar
        tabViewController.title = "Settings"

        // General tab
        let generalTab = NSTabViewItem(viewController: SettingsGeneralViewController())
        generalTab.label = "General"
        generalTab.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        tabViewController.addTabViewItem(generalTab)

        // About tab
        let aboutTab = NSTabViewItem(viewController: SettingsAboutViewController())
        aboutTab.label = "About"
        aboutTab.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")
        tabViewController.addTabViewItem(aboutTab)

        let window = NSWindow(contentViewController: tabViewController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 300))
        window.center()

        self.init(window: window)
    }
}

// MARK: - SettingsGeneralViewController

/// The "General" tab content: default view mode, show hidden files, icon style.
private final class SettingsGeneralViewController: NSViewController {
    private let viewModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hiddenFilesCheckbox = NSButton(checkboxWithTitle: "Show hidden files", target: nil, action: nil)
    private let iconStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let terminalPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))

        configureViewModePopup()
        configureHiddenFilesCheckbox()
        configureIconStylePopup()
        configureTerminalPopup()
        layoutControls()
    }

    // MARK: - Configuration

    private static let defaultViewModeKey = "scout.defaultViewMode"

    private func configureViewModePopup() {
        viewModePopup.addItems(withTitles: ["List", "Icon", "Column", "Gallery"])
        viewModePopup.target = self
        viewModePopup.action = #selector(viewModeChanged(_:))

        // Load current default from UserDefaults
        let raw = UserDefaults.standard.string(forKey: Self.defaultViewModeKey) ?? ViewMode.list.rawValue
        let mode = ViewMode(rawValue: raw) ?? .list
        switch mode {
        case .list: viewModePopup.selectItem(withTitle: "List")
        case .icon: viewModePopup.selectItem(withTitle: "Icon")
        case .column: viewModePopup.selectItem(withTitle: "Column")
        case .gallery: viewModePopup.selectItem(withTitle: "Gallery")
        }
    }

    private func configureHiddenFilesCheckbox() {
        hiddenFilesCheckbox.target = self
        hiddenFilesCheckbox.action = #selector(hiddenFilesChanged(_:))

        let showHidden = PersistenceService.shared.loadShowHiddenFiles()
        hiddenFilesCheckbox.state = showHidden ? .on : .off
    }

    private func configureIconStylePopup() {
        iconStylePopup.addItems(withTitles: ["System", "Flat"])
        iconStylePopup.target = self
        iconStylePopup.action = #selector(iconStyleChanged(_:))

        let currentStyle = PersistenceService.shared.loadIconStyle()
        switch currentStyle {
        case .system: iconStylePopup.selectItem(withTitle: "System")
        case .flat: iconStylePopup.selectItem(withTitle: "Flat")
        }
    }

    private func configureTerminalPopup() {
        let installed = TerminalLaunchService.installedTerminals()
        terminalPopup.addItems(withTitles: installed.map(\.displayName))
        terminalPopup.target = self
        terminalPopup.action = #selector(terminalChanged(_:))

        let current = TerminalLaunchService.preferredTerminal
        terminalPopup.selectItem(withTitle: current.displayName)
    }

    private func layoutControls() {
        let viewModeLabel = NSTextField(labelWithString: "Default view mode:")
        viewModeLabel.alignment = .right
        let iconStyleLabel = NSTextField(labelWithString: "Icon style:")
        iconStyleLabel.alignment = .right
        let terminalLabel = NSTextField(labelWithString: "Default terminal:")
        terminalLabel.alignment = .right

        let gridView = NSGridView(views: [
            [viewModeLabel, viewModePopup],
            [NSGridCell.emptyContentView, hiddenFilesCheckbox],
            [iconStyleLabel, iconStylePopup],
            [terminalLabel, terminalPopup],
        ])
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.rowSpacing = 12
        gridView.columnSpacing = 8
        gridView.column(at: 0).xPlacement = .trailing

        view.addSubview(gridView)

        NSLayoutConstraint.activate([
            gridView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gridView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func viewModeChanged(_ sender: NSPopUpButton) {
        let mode: ViewMode
        switch sender.titleOfSelectedItem {
        case "Icon": mode = .icon
        case "Column": mode = .column
        case "Gallery": mode = .gallery
        default: mode = .list
        }

        UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultViewModeKey)
    }

    @objc private func hiddenFilesChanged(_ sender: NSButton) {
        let show = sender.state == .on
        PersistenceService.shared.saveShowHiddenFiles(show)

        // Notify the key window's MainWindowController
        if let windowController = NSApp.keyWindow?.windowController as? MainWindowController {
            if windowController.showHiddenFiles != show {
                windowController.toggleShowHiddenFiles()
            }
        }
    }

    @objc private func iconStyleChanged(_ sender: NSPopUpButton) {
        let style: IconStyle = sender.titleOfSelectedItem == "Flat" ? .flat : .system
        PersistenceService.shared.saveIconStyle(style)

        // Notify the key window's MainWindowController
        if let windowController = NSApp.keyWindow?.windowController as? MainWindowController {
            windowController.setIconStyle(style)
        }
    }

    @objc private func terminalChanged(_ sender: NSPopUpButton) {
        let installed = TerminalLaunchService.installedTerminals()
        if let index = sender.indexOfSelectedItem as Int?,
           index >= 0, index < installed.count
        {
            TerminalLaunchService.preferredTerminal = installed[index]
        }
    }
}

// MARK: - SettingsAboutViewController

/// The "About" tab content: app icon, name, version.
private final class SettingsAboutViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        // App icon
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])
        stack.addArrangedSubview(iconView)

        // App name
        let appName = ProcessInfo.processInfo.processName
        let nameLabel = NSTextField(labelWithString: appName)
        nameLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        nameLabel.alignment = .center
        stack.addArrangedSubview(nameLabel)

        // Version
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        stack.addArrangedSubview(versionLabel)

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
