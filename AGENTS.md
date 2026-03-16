# Scout

The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project. If you ever encounter something in the project that surprises you, please alert the developer working with you and indicate that this is the case in the AGENTS.md file to help prevent future agents from having the same issue.

## Pre-Launch Status

**This app has NOT launched yet.** There are no production users or data to migrate.

- **NO backwards compatibility code** — Delete old code, don't deprecate it
- **NO migration shims** — Just change the API directly
- **NO feature flags for old behavior** — Remove the old behavior entirely
- **Breaking changes are preferred** — Clean, simple code over compatibility layers

If you find yourself writing compatibility code, stop and make the breaking change instead.

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
make test       # Run tests
make clean      # Remove all build artifacts
make lint       # Run swiftformat --lint + build
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

- `Sources/Scout/App/main.swift` — Thin executable entry point (imports `ScoutLib`)
- `Sources/ScoutLib/App/` — `AppDelegate`
- `Sources/ScoutLib/Models/` — Data models (`FileItem`, `ViewSettings`, `Workspace`, etc.)
- `Sources/ScoutLib/Views/` — AppKit view controllers and window controllers
- `Sources/ScoutLib/Controllers/` — Business logic controllers
- `Sources/ScoutLib/Services/` — File system, search, persistence services
- `Sources/ScoutLib/Utilities/` — Extensions and keyboard shortcuts
- `Sources/ScoutLib/Resources/` — Info.plist, entitlements, assets, icons
- `Sources/CSearchfs/` — C module for `searchfs(2)` syscall integration
- `Tests/ScoutDropTests/` — Tests (`@testable import ScoutLib`)

## Key Technical Notes

- The project uses a library+executable split: `ScoutLib` (library) contains all code, `Scout` (executable) is a thin wrapper that imports `ScoutLib` and starts the app. This improves SourceKit-LSP indexing and enables `@testable import` for tests.
- SPM executables require `app.setActivationPolicy(.regular)` to appear as GUI apps
- App bundle is manually assembled from SPM output (see Makefile `app` target)
- Icon PNGs have pre-rendered macOS squircle mask (superellipse n=5.0)
- Asset catalog is compiled with `actool`, bundle is ad-hoc code signed
- Global hotkey (Opt+Space) uses CGEvent tap, requires accessibility permissions

## Common Mistakes

Prefer principle-first entries here: capture the reusable rule behind the bug, then keep only the minimum repo-specific detail needed to apply it correctly.

### This is AppKit, not SwiftUI (agents consistently get this wrong)

- **Never suggest SwiftUI components.** This app is 100% AppKit. Do not use `NSHostingView`, `@Observable`, `@State`, `@Binding`, `some View`, or any SwiftUI type.
- Use `NSViewController`, `NSView`, `NSWindowController`, and delegate patterns.
- If you see a pattern online that uses SwiftUI, translate it to AppKit before suggesting it.

### Library+executable split (imports matter)

- All application code goes in `Sources/ScoutLib/`, not `Sources/Scout/`
- `Sources/Scout/App/main.swift` is a thin entry point — do not add code there
- Tests import `@testable import ScoutLib`, not `Scout`
- New source files belong in `ScoutLib` under the appropriate subdirectory

### SwiftFormat runs automatically (do not fight it)

- `.swiftformat` config enforces the project style (4-space indent, no `self.`, 120 max width)
- Claude Code hooks auto-format every Swift file after editing
- CI runs `swiftformat --lint .` — if your code doesn't match, CI fails
- Do not add `// swiftformat:disable` comments unless absolutely necessary

### SPM bundle assembly is manual (no Xcode project)

- There is no `.xcodeproj` or `.xcworkspace` — do not create one
- The `.app` bundle is assembled by `make app` using the Makefile, not Xcode
- `actool` compiles the asset catalog, `codesign` signs the bundle
- If you need to add a new resource, update `Package.swift` resources array and the Makefile if needed

### Window toolbar overlap (surprising AppKit behavior)

- `titlebarAppearsTransparent = true` causes the content view to extend behind the toolbar, even without `.fullSizeContentView` in the style mask
- `window.contentLayoutRect` returns the **full content area** when `titlebarAppearsTransparent` is set — it does NOT exclude the toolbar. Do not use it to compute toolbar height.
- `view.safeAreaLayoutGuide.topAnchor` does NOT propagate correctly through NSSplitView subview hierarchies
- `NSScrollView.contentInsets.top` is only auto-set when the scroll view itself extends into the toolbar area
- **Correct toolbar height formula**: `window.frame.height - (window.contentView?.frame.maxY ?? window.frame.height)` — this gives the actual title bar + toolbar overlap on the content view
- Views at `view.topAnchor` will be hidden behind the toolbar; offset them by the computed toolbar height in `viewDidLayout()`

### NSView drawing and z-order (easy to cause visual bugs)

- **Never use `NSView.draw(_ dirtyRect:)` with `dirtyRect.fill()` for background views** — the dirtyRect can bleed beyond the view's bounds when the view is layered above siblings, painting over unrelated content. Use layer-backed backgrounds instead: `view.wantsLayer = true; view.layer?.backgroundColor = color.cgColor`
- Update layer backgrounds on appearance change since `layer.backgroundColor` doesn't auto-adapt (observe `effectiveAppearance`)
- Subview order = z-order in AppKit. Later subviews draw on top. If a header must overlay content, add it to the superview **after** the content views
- When views at different Y positions still visually overlap, check if a `draw()` override is painting outside its bounds

### NSBox separator height (surprising intrinsic size)

- `NSBox(boxType: .separator)` has an intrinsic height of ~5px that overrides explicit height constraints
- For a true 1px separator, use `NSBox(boxType: .custom)` with `borderWidth = 0`, `fillColor = .separatorColor`, and an explicit height constraint

### NSRulerView is broken on macOS 14+ (do not use)

- `NSRulerView` subclasses break on macOS 14+ (Sonoma) due to Apple's `clipsToBounds` default change — text content disappears or renders incorrectly (documented in Apple Forums and affected projects like Scintilla, CotEditor)
- The modern pattern (used by CotEditor, TextViewLineNumbers, and this project) is a standalone `NSView` alongside (not inside) the scroll view, synced via `boundsDidChangeNotification` on the scroll view's clip view
- Our `LineNumberRulerView` follows this pattern with O(log n) binary search line lookup and dynamic gutter width

### Swift language mode v5 with Swift 6.2+ toolchain

- `Package.swift` sets `.swiftLanguageMode(.v5)` on all targets — this means strict concurrency checking is not fully enforced yet
- Do not add `@Sendable`, `sending`, or `@MainActor` annotations preemptively unless fixing a real warning
- Do not set `swift-tools-version` to 6.1+ without discussion — it changes default language mode behavior

### Canonical module locations (don't create duplicates)

- **Models**: `Sources/ScoutLib/Models/` — `FileItem`, `ViewSettings`, `Workspace`, etc.
- **Views**: `Sources/ScoutLib/Views/` — All view controllers and window controllers
- **Controllers**: `Sources/ScoutLib/Controllers/` — Business logic controllers
- **Services**: `Sources/ScoutLib/Services/` — File system, search, persistence services
- **Utilities**: `Sources/ScoutLib/Utilities/` — Extensions and keyboard shortcuts
- **Resources**: `Sources/ScoutLib/Resources/` — Info.plist, entitlements, assets, icons
- Do not create new top-level directories under `Sources/ScoutLib/` without discussion

### Documentation drift

- The canonical docs are listed in `docs/DOCUMENTATION.md`
- If you change architecture, build process, or public interfaces, update the affected canonical doc in the same change
- `CLAUDE.md` is a symlink to `AGENTS.md` — edit `AGENTS.md`, not the symlink
