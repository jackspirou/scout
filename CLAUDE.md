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
