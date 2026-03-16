# Scout

A modern file manager for macOS.

[![CI](https://github.com/jackspirou/scout/actions/workflows/ci.yml/badge.svg)](https://github.com/jackspirou/scout/actions/workflows/ci.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)

Scout is a native macOS file manager built with Swift and AppKit, designed to
replace Finder for power users. It is fast, keyboard-first, and features
tabbed browsing with session memory that makes file management efficient.

![Scout](docs/screenshot.png)

## Why Scout?

Finder has served macOS well for decades, but it falls short for users who
demand more from their file manager:

- **No true cut-and-paste.** Finder only supports copy-paste. Moving files
  requires dragging or using a keyboard shortcut that is easy to forget.
- **No tabs with memory.** Comparing or moving files between directories
  means juggling multiple windows with no state memory.
- **View settings do not persist.** Switching a folder to list view resets the
  next time you open it.
- **Weak search.** Finder search is slow and lacks scoped filtering by file
  kind, size, date, or tags.
- **No command palette.** There is no quick way to access actions without
  memorizing menu bar paths or shortcuts.

## Features

- [x] True cut/copy/move (Cmd+X/C/V)
- [x] Tabbed browsing with per-tab selection and scroll memory
- [x] Inline preview pane for images, text, audio, video, and PDFs
- [x] Persistent per-folder view settings
- [x] Keyboard-first navigation
- [x] Command palette (Cmd+Shift+P)
- [x] Named workspaces — save and restore window layouts
- [x] Session restore — tabs, selections, and scroll positions on relaunch
- [x] Scoped search with searchfs(2) for instant filename matching
- [x] Global hotkey (Opt+Space) to summon Scout from anywhere

## Planned

- Cloud storage integration
- Git status indicators
- Plugin API
- AI-powered search

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel

## Install

### Download

Grab the latest `.dmg` or `.app.zip` from
[Releases](https://github.com/jackspirou/scout/releases).

### Build from source

```
git clone https://github.com/jackspirou/scout.git
cd scout
make app
make install
```

## Development

Build and run Scout locally using the provided Makefile targets:

```
make build    # Compile the project
make run      # Build and launch Scout
make release  # Build with release optimizations
make app      # Package as a .app bundle
make dmg      # Create a distributable .dmg image
```

## Keyboard Shortcuts

| Action                  | Shortcut         |
|-------------------------|------------------|
| Toggle preview pane     | Cmd+Shift+Space  |
| Cut                     | Cmd+X            |
| Copy                    | Cmd+C            |
| Paste / Move            | Cmd+V            |
| Command palette         | Cmd+Shift+P      |
| Search                  | Cmd+F            |
| New tab                 | Cmd+T            |
| Close tab               | Cmd+W            |
| Next tab                | Ctrl+Tab         |
| Previous tab            | Ctrl+Shift+Tab   |
| Go to parent directory  | Cmd+Up           |
| Open selected item      | Enter            |
| Quick Look preview      | Space            |
| Toggle hidden files     | Cmd+Shift+.      |
| Rename                  | F2               |
| Delete                  | Cmd+Backspace    |
| New folder              | Cmd+Shift+N      |
| Path bar editing        | Cmd+L            |
| Save workspace          | Ctrl+Cmd+S       |
| Summon Scout            | Opt+Space        |

## License

Scout is licensed under the [GNU Affero General Public License v3.0](LICENSE).

## Contributing

Contributions welcome! Please open an issue to discuss before submitting a PR.
