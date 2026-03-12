# CLAUDE.md — Scout Project Guidelines

## Project Overview
Scout is a native macOS file manager built with Swift/AppKit, replacing Finder.
- **Language**: Swift 6.2+ with Swift language mode v5
- **UI Framework**: AppKit (not SwiftUI)
- **Build System**: Swift Package Manager (no Xcode project)
- **Target**: macOS 14+ (Sonoma)
- **License**: AGPLv3

## Build & Run
```bash
make build      # Debug build
make release    # Release build
make app        # Assemble .app bundle (includes actool + codesign)
make run        # Build and launch debug binary
make install    # Copy .app to /Applications
make clean      # Remove all build artifacts
make changelog  # Regenerate CHANGELOG.md via git-cliff
```

## Commit Convention
This project uses **conventional commits** for automated changelog generation with `git-cliff`.

### Format
```
<type>(<optional scope>): <description>

<optional body>

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

### Types
- `feat:` — New feature
- `fix:` — Bug fix
- `refactor:` — Code change that neither fixes a bug nor adds a feature
- `perf:` — Performance improvement
- `docs:` — Documentation only
- `style:` — Formatting, missing semicolons, etc.
- `test:` — Adding or updating tests
- `chore:` — Maintenance, dependencies, tooling
- `ci:` — CI/CD changes
- `build:` — Build system or external dependency changes

### Examples
```
feat: add column view mode to file browser
fix(pathbar): handle spaces in directory names
refactor(transfer): simplify queue state machine
ci: add macOS 15 to CI matrix
```

## Architecture
- `Sources/Scout/App/` — Entry point (`main.swift`), `AppDelegate`
- `Sources/Scout/Models/` — Data models (`FileItem`, `ViewSettings`, `Workspace`, etc.)
- `Sources/Scout/Views/` — AppKit view controllers and window controllers
- `Sources/Scout/Controllers/` — Business logic controllers
- `Sources/Scout/Services/` — File system, search, persistence services
- `Sources/Scout/Utilities/` — Extensions and keyboard shortcuts
- `Sources/Scout/Resources/` — Info.plist, entitlements, assets, icons

## Key Technical Notes
- SPM executables require `app.setActivationPolicy(.regular)` to appear as GUI apps
- App bundle is manually assembled from SPM output (see Makefile `app` target)
- Icon PNGs have pre-rendered macOS squircle mask (superellipse n=5.0)
- Asset catalog is compiled with `actool`, bundle is ad-hoc code signed
- Global hotkey (Opt+Space) uses CGEvent tap, requires accessibility permissions

## AppKit Pitfalls & Patterns

### Window Toolbar Overlap
- `titlebarAppearsTransparent = true` causes the content view to extend behind the toolbar, even without `.fullSizeContentView` in the style mask
- `window.contentLayoutRect` returns the **full content area** when `titlebarAppearsTransparent` is set — it does NOT exclude the toolbar. Do not use it to compute toolbar height.
- `view.safeAreaLayoutGuide.topAnchor` does NOT propagate correctly through NSSplitView subview hierarchies
- `NSScrollView.contentInsets.top` is only auto-set when the scroll view itself extends into the toolbar area
- **Correct toolbar height formula**: `window.frame.height - (window.contentView?.frame.maxY ?? window.frame.height)` — this gives the actual title bar + toolbar overlap on the content view
- Views at `view.topAnchor` will be hidden behind the toolbar; offset them by the computed toolbar height in `viewDidLayout()`

### NSView Drawing & Z-Order
- **Never use `NSView.draw(_ dirtyRect:)` with `dirtyRect.fill()` for background views** — the dirtyRect can bleed beyond the view's bounds when the view is layered above siblings, painting over unrelated content. Use layer-backed backgrounds instead: `view.wantsLayer = true; view.layer?.backgroundColor = color.cgColor`
- Update layer backgrounds on appearance change since `layer.backgroundColor` doesn't auto-adapt (observe `effectiveAppearance`)
- Subview order = z-order in AppKit. Later subviews draw on top. If a header must overlay content, add it to the superview **after** the content views
- When views at different Y positions still visually overlap, check if a `draw()` override is painting outside its bounds

### NSBox Separator
- `NSBox(boxType: .separator)` has an intrinsic height of ~5px that overrides explicit height constraints
- For a true 1px separator, use `NSBox(boxType: .custom)` with `borderWidth = 0`, `fillColor = .separatorColor`, and an explicit height constraint

### NSRulerView vs Custom Line Numbers
- `NSRulerView` subclasses break on macOS 14+ (Sonoma) due to Apple's `clipsToBounds` default change — text content disappears or renders incorrectly (documented in Apple Forums and affected projects like Scintilla, CotEditor)
- The modern pattern (used by CotEditor, TextViewLineNumbers, and this project) is a standalone `NSView` alongside (not inside) the scroll view, synced via `boundsDidChangeNotification` on the scroll view's clip view
- Our `LineNumberRulerView` follows this pattern with O(log n) binary search line lookup and dynamic gutter width
