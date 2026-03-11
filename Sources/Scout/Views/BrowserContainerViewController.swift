import Cocoa

// MARK: - BrowserContainerViewController

final class BrowserContainerViewController: NSViewController {
    // MARK: - Properties

    private let splitView = NSSplitView()
    private let clipboardManager: ClipboardManager
    private let leftPane: BrowserPaneViewController
    private let rightPane: BrowserPaneViewController

    private var isDualPane: Bool = false

    // MARK: - Init

    init(clipboardManager: ClipboardManager = ClipboardManager()) {
        self.clipboardManager = clipboardManager
        leftPane = BrowserPaneViewController(clipboardManager: clipboardManager)
        rightPane = BrowserPaneViewController(clipboardManager: clipboardManager)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Tracks which pane currently holds focus. `true` means the left pane is active.
    private var leftPaneIsActive: Bool = true

    // MARK: - Constants

    private enum Layout {
        static let minimumPaneWidth: CGFloat = 300
        static let animationDuration: TimeInterval = 0.25
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        configureSplitView()
        addPanes()
        layoutSplitView()
        updateActiveIndicator()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Start in single-pane mode
        rightPane.view.isHidden = true
        splitView.adjustSubviews()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(leftPane.view)
    }

    // MARK: - Configuration

    private func configureSplitView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.delegate = self
        view.addSubview(splitView)
    }

    private func addPanes() {
        addChild(leftPane)
        splitView.addSubview(leftPane.view)

        addChild(rightPane)
        splitView.addSubview(rightPane.view)
    }

    private func layoutSplitView() {
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Public API

    /// Toggles between single-pane and dual-pane mode with animation.
    func toggleDualPane() {
        isDualPane.toggle()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.allowsImplicitAnimation = true

            if isDualPane {
                rightPane.view.isHidden = false
                let halfWidth = splitView.bounds.width / 2
                splitView.setPosition(halfWidth, ofDividerAt: 0)
            } else {
                rightPane.view.isHidden = true
                leftPaneIsActive = true
                updateActiveIndicator()
            }

            splitView.adjustSubviews()
        }
    }

    /// Returns the currently active (focused) pane controller.
    func activePaneController() -> BrowserPaneViewController {
        leftPaneIsActive ? leftPane : rightPane
    }

    /// The inactive pane controller (nil if single-pane mode).
    func inactivePaneController() -> BrowserPaneViewController? {
        guard isDualPane else { return nil }
        return leftPaneIsActive ? rightPane : leftPane
    }

    // MARK: - Focus Management

    /// Switches active focus between left and right panes.
    func switchFocus() {
        guard isDualPane else { return }
        leftPaneIsActive.toggle()
        updateActiveIndicator()

        let targetPane = activePaneController()
        view.window?.makeFirstResponder(targetPane.view)
    }

    private func updateActiveIndicator() {
        leftPane.setActive(isDualPane && leftPaneIsActive)
        rightPane.setActive(isDualPane && !leftPaneIsActive)
    }

    // MARK: - Key Handling

    override func keyDown(with event: NSEvent) {
        // Tab key switches focus between panes
        if event.keyCode == 48 /* Tab */, isDualPane {
            switchFocus()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - NSSplitViewDelegate

extension BrowserContainerViewController: NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        Layout.minimumPaneWidth
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        splitView.bounds.width - Layout.minimumPaneWidth
    }

    func splitView(
        _ splitView: NSSplitView,
        canCollapseSubview subview: NSView
    ) -> Bool {
        subview === rightPane.view
    }

    func splitView(
        _ splitView: NSSplitView,
        shouldHideDividerAt dividerIndex: Int
    ) -> Bool {
        !isDualPane
    }
}
