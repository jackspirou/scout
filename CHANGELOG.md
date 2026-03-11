# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0-alpha.2] - 2026-03-11

### Added
- App icon (bulldog) with pre-rendered macOS squircle mask at all standard sizes
- Asset catalog (Assets.xcassets) with complete icon set
- PkgInfo file generation for proper bundle identification
- actool asset catalog compilation in build pipeline
- Ad-hoc code signing in build pipeline
- GUI activation policy so app appears in Dock properly

### Fixed
- SPM binary path resolution in Makefile (uses `swift build --show-bin-path`)
- Release workflow now matches local build (actool, codesign, PkgInfo)

## [0.1.0-alpha.1] - 2026-03-11

### Added
- Initial project scaffolding with Swift Package Manager
- Dual-pane file browser with split view layout
- True cut, copy, and move file operations
- Per-folder persistent view settings
- Keyboard-first navigation with optional vim bindings
- Command palette for quick action access
- Scoped search with filter tokens (kind, size, date, tags)
- File transfer queue with progress tracking, pause, and resume
- Tabbed browsing with pinned tabs and session restore
- Workspace save and restore
- Global hotkey (Opt+Space) to summon Scout
- Path bar with breadcrumb navigation and direct path editing
- Context menus for file operations
- Drag and drop between panes
