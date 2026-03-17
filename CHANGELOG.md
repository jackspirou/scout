# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0-beta.9] - 2026-03-17

### Fixed

- **ci**: Sign DMG before notarization and add log on failure

## [0.1.0-beta.8] - 2026-03-17

### Fixed

- **ci**: Add secure timestamp and strip debug entitlements

## [0.1.0-beta.7] - 2026-03-17

### Fixed

- **ci**: Enable hardened runtime and log notarization failures

## [0.1.0-beta.6] - 2026-03-17

### Fixed

- **ci**: Pass DEVELOPMENT_TEAM from secrets for code signing

## [0.1.0-beta.5] - 2026-03-17

### Build

- Switch to XcodeGen + xcodebuild for release builds

### CI/CD

- Add code signing and notarization to release workflow

### Documentation

- Update CHANGELOG.md for v0.1.0-beta.4

## [0.1.0-beta.4] - 2026-03-17

### CI/CD

- Auto-update Homebrew cask on release

### Documentation

- Update CHANGELOG.md for v0.1.0-beta.3

### Fixed

- Copy SPM resource bundles into app bundle

### Styling

- Fix swiftformat lint in screenshot script

## [0.1.0-beta.3] - 2026-03-17

### Added

- UX improvements — toolbar, sidebar workspaces, tab bar, and bug fixes
- Automated screenshot capture for releases

### Documentation

- Update CHANGELOG.md for v0.1.0-beta.2

### Fixed

- Use ScreenCaptureKit for screenshot tool and update README
- **ci**: Remove screenshot step from release workflow

## [0.1.0-beta.2] - 2026-03-16

### Added

- Session restore, workspace UI, and tab state management

### Documentation

- Update CHANGELOG.md for v0.1.0-beta.1

### Styling

- Simplify redundant property in search results closure

## [0.1.0-beta.1] - 2026-03-16

### Added

- Add ScoutDrop file transfer, searchfs, TOFU identity, and self-device filtering
- Preview improvements, hidden files, spacebar playback, and code health fixes
- Professional FFT spectrum visualization with spectral tilt compensation
- Add image, PDF, video, and directory preview with metadata
- Add collapsible metadata header, preview container, and AppKit docs

### CI/CD

- Add swiftformat lint step and SPM dependency caching

### Changed

- Split Scout into ScoutLib library + thin executable
- Deduplicate services, extract models, add protocols, simplify FileItem
- Major codebase cleanup, architecture improvements, and zero-warning build

### Fixed

- MTAudioProcessingTap API compatibility for Swift 6.1

### Miscellaneous

- Add git-cliff changelog generation and CLAUDE.md project guidelines

### Styling

- Apply swiftformat to all source files

## [0.1.0-alpha.2] - 2026-03-11

## [0.1.0-alpha] - 2026-03-11


