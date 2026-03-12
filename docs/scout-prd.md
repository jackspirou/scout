# Product Requirements Document: Scout

**A Modern File Manager for macOS**

| Field          | Value                |
|----------------|----------------------|
| Version        | 1.0 — MVP            |
| Date           | March 2026           |
| Status         | Draft                |
| Author         | [Product Lead]       |
| Target Release | Q4 2026              |

---

## 1. Executive Summary

Scout is a native macOS file manager designed to replace Finder for users who need more power, speed, and control over their file system. It addresses a decade of accumulated frustrations with Finder's stagnation: inconsistent views, weak search, missing cut-and-paste, no dual-pane mode, poor keyboard navigation, and a lack of workflow memory.

The MVP targets intermediate-to-advanced Mac users — developers, designers, content creators, and knowledge workers — who manage large file volumes daily and have considered (or already adopted) third-party Finder replacements. Scout will ship as a standalone macOS app that can coexist with Finder or serve as a full replacement.

## 2. Problem Statement

macOS Finder has not received a meaningful feature overhaul in over a decade. While the broader ecosystem has advanced — better window management, Spotlight improvements, Apple Silicon performance — Finder's core file management experience has stagnated. The result:

- No true cut-and-paste for files; the hidden Cmd+Option+V workaround is undiscoverable
- Search is unreliable, returning results from outside the current scope or missing known files entirely
- View settings (icon, list, column) don't persist consistently across folders
- No dual-pane layout for comparing or moving files between locations
- No workflow memory — no clipboard history, no recent-files trail, no session restore
- Poor keyboard navigation: Enter renames instead of opening; no global shortcut to summon a window
- Weak file transfer UX: no speed display, no pause/resume, no queue, poor conflict resolution
- Unreliable network volume handling: dropped connections, slow transfers, no auto-reconnect

A cottage industry of third-party replacements (Path Finder, Forklift, Commander One, QSpace) proves the demand. Scout aims to be the definitive alternative: native, fast, and designed around real workflows.

## 3. Target Users

### 3.1 Primary Personas

| Persona          | Description                                                                                         | Key Pain Points                                                                                  |
|------------------|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| Power Dev        | Software engineer managing repos, build artifacts, logs, configs across multiple projects daily      | No terminal integration, no dual-pane, weak search, no batch rename with regex                   |
| Creative Pro     | Designer or video editor working with large asset libraries, version folders, and deliverables       | No robust preview, poor file transfer progress, view settings resetting, can't tag efficiently    |
| Knowledge Worker | Writer, researcher, or PM juggling documents, downloads, shared folders, and cloud sync             | No session memory, poor recent-files access, no workflow shortcuts, slow navigation              |

### 3.2 Out of Scope for MVP

- Casual users who rarely interact with the file system directly
- IT administrators needing enterprise deployment/MDM integration
- Users primarily on iOS/iPadOS (no cross-platform MVP)

## 4. Goals & Success Metrics

### 4.1 Product Goals

- Replace Finder as the daily file manager for power users within the first session
- Reduce average time-to-file-action (open, move, find) by 40% versus stock Finder
- Achieve feature parity with the top 3 Finder alternatives on core file operations
- Deliver a native, performant experience that feels like a first-party Apple app

### 4.2 MVP Success Metrics

| Metric                   | Target                                    | Measurement                          |
|--------------------------|-------------------------------------------|--------------------------------------|
| Beta retention (30-day)  | 60%+ daily active users                   | Analytics / telemetry                |
| Finder launch reduction  | Users open Finder <3x/day after 1 week    | Self-reported + system logs          |
| NPS score                | >50 among beta cohort                     | In-app survey at day 14             |
| Task completion speed    | 40% faster on 5 benchmark tasks           | Usability testing                    |
| Crash rate               | <0.5% of sessions                         | Crash reporting (Sentry)             |

## 5. MVP Feature Requirements

Features are organized by priority tier. The MVP ships Tier 1 (must-have) and Tier 2 (should-have) features. Tier 3 features are designed but deferred to v1.1.

### 5.1 Tier 1 — Must Have

#### 5.1.1 Dual-Pane Layout

- Side-by-side file browser panes, each independently navigable
- One-key file move/copy between panes (e.g., F5 copy, F6 move, following convention)
- Toggle between single-pane and dual-pane with a keyboard shortcut (Cmd+D)
- Each pane maintains its own view mode, sort order, and path history
- Drag-and-drop between panes with visual drop indicators

#### 5.1.2 True Cut, Copy, Move

- Cmd+X cuts files (dims icons at source); Cmd+V pastes/moves to destination
- Cmd+C / Cmd+V copies as expected
- Visual indicators: cut files show 50% opacity; copied files show a badge
- Conflict resolution dialog on paste: Replace, Skip, Keep Both, Rename, Apply to All
- Undo support for the last move/copy/delete operation (Cmd+Z)

#### 5.1.3 Persistent, Consistent Views

- View mode (icon, list, column, gallery) persists per-folder and across sessions
- Global default view mode with per-folder overrides
- Sort order (name, date, size, kind, tags) persists per-folder
- Column widths and visible columns persist in list view
- "Apply to all subfolders" option to cascade view settings

#### 5.1.4 Keyboard-First Navigation

- Global hotkey to summon Scout from any app (configurable, default: Opt+Space)
- Enter opens the selected file/folder (not rename — rename is mapped to F2)
- Full keyboard navigation: arrow keys, Tab to switch panes, Cmd+Up for parent
- Inline path bar: click to navigate, type to edit path directly (Cmd+L)
- Command palette (Cmd+Shift+P) for all actions: go to folder, run command, toggle settings
- Vim-style optional key bindings (j/k/h/l navigation, toggled in preferences)

#### 5.1.5 Reliable, Scoped Search

- Search scoped to current folder by default; option to expand to full disk or specific locations
- Instant fuzzy matching on filenames as you type
- Filter tokens: `kind:pdf`, `size:>10mb`, `modified:today`, `tag:work` (autocomplete suggestions)
- Results grouped by location with clear folder breadcrumbs
- Search results are actionable in-place: rename, move, delete, open, Quick Look
- Index-based search using macOS Spotlight index for speed; manual re-index option

#### 5.1.6 File Transfer Engine

- Queue-based transfers: operations run sequentially by default, parallel as an option
- Transfer HUD showing: file name, speed, time remaining, progress bar
- Pause, resume, cancel individual transfers or the entire queue
- Conflict resolution with memory: "always skip duplicates" per session
- Post-transfer summary: X files moved, Y skipped, Z failed (with retry option)

### 5.2 Tier 2 — Should Have

#### 5.2.1 Tabbed Browsing

- Multiple tabs per pane, with Cmd+T to open, Cmd+W to close
- Tab dragging to reorder or split into new pane
- Pinned tabs that persist across sessions
- Tab groups that can be saved and restored by name (e.g., "Project Alpha")

#### 5.2.2 Session Memory & Workspaces

- On launch, restore last session: all tabs, panes, scroll positions, selections
- Named workspaces: save a full window layout (tabs, panes, paths) and switch between them
- Recent locations sidebar: last 20 visited folders, sorted by recency or frequency
- Clipboard history for file operations: last 10 cut/copy operations, accessible via Cmd+Shift+V

#### 5.2.3 Quick Look & Preview Pane

- Integrated preview pane (toggleable, docked to right or bottom)
- Supports images, PDFs, markdown, code (with syntax highlighting), video, audio
- Preview updates instantly on selection change
- Spacebar triggers full Quick Look (consistent with macOS convention)

#### 5.2.4 Batch Operations

- Multi-rename: pattern-based renaming with live preview (e.g., `IMG_{n}.jpg`, regex support)
- Batch tagging: apply/remove macOS tags to selected files
- Batch move: select files across search results and move to a chosen destination
- Compress/extract with progress (zip, tar.gz, 7z)

#### 5.2.5 Terminal Integration

- "Open Terminal Here" on any folder (configurable: Terminal, iTerm2, Warp, Kitty)
- Embedded mini-terminal drawer at the bottom of the window (toggle with backtick)
- Drag file/folder into terminal to paste its path

### 5.3 Tier 3 — Post-MVP (v1.1+)

- Cloud storage integration (iCloud, Dropbox, Google Drive, S3) as native sidebar mounts
- Git status indicators on files and folders (modified, untracked, conflicts)
- Plugin/extension API for community-built integrations
- Folder size calculation and disk usage visualization (treemap)
- Smart folders with saved, auto-updating search queries
- Network volume manager: saved connections, auto-reconnect, performance monitoring
- Multi-window sync: action in one window reflects immediately in all open windows
- AI-powered features: natural language search, auto-tagging, duplicate detection

## 6. UX & Design Principles

1. **Native and familiar.** Scout should feel like a first-party Apple app. Use standard macOS controls, respect system appearance (light/dark mode, accent colors), and follow the HIG unless there's a strong usability reason to diverge.

2. **Keyboard-first, mouse-friendly.** Every action must be achievable by keyboard. But the mouse/trackpad experience should be equally polished — no "power-user-only" traps.

3. **Progressive disclosure.** The default experience is clean and simple. Advanced features (dual-pane, command palette, regex rename) are one shortcut or toggle away, never cluttering the default view.

4. **Speed is a feature.** Window open: <200ms. Search results: <100ms for first results. Directory listing of 10,000 files: <500ms. Anything slower is a bug.

5. **Respect muscle memory.** Cmd+C/V/Z, Spacebar for Quick Look, arrow keys for navigation. Don't reinvent what already works — fix what doesn't.

6. **Transparency over magic.** Show what's happening: transfer speeds, operation progress, file counts. Never hide state from the user.

## 7. Technical Architecture

### 7.1 Platform & Stack

| Component         | Technology                                                                          |
|-------------------|-------------------------------------------------------------------------------------|
| Language          | Swift 5.9+ with structured concurrency                                              |
| UI Framework      | AppKit (not SwiftUI — AppKit gives finer control over file browser UX and performance) |
| File system layer | Foundation FileManager + POSIX APIs for low-level operations                        |
| Search            | NSMetadataQuery (Spotlight index) + custom filename index for instant fuzzy matching |
| Persistence       | SQLite (via GRDB) for session state, view prefs, workspace configs                  |
| IPC / Extensions  | XPC services for sandboxed file operations; Finder Sync extension for badge overlays |
| Min. macOS version| macOS 14 (Sonoma)                                                                   |

### 7.2 Performance Requirements

- Cold launch to usable window: <1 second on Apple Silicon, <2 seconds on Intel
- Directory listing (10K files): <500ms to first render, progressive load for 100K+
- Search: first results in <100ms; full results for 1M+ file index in <2 seconds
- File copy throughput: within 5% of Finder's throughput on same hardware
- Memory: <150MB baseline; <500MB with 20 tabs and dual-pane open
- Smooth 60fps scrolling through lists of 100K+ files (virtual/recycled list views)

### 7.3 Security & Sandboxing

- Distributed as a sandboxed app via the Mac App Store (primary) and direct download (secondary)
- Full Disk Access entitlement required; requested at first launch with clear explanation
- No data collection beyond opt-in anonymous crash reports and usage analytics
- All file operations use system-level APIs; no custom kernel extensions

## 8. Competitive Analysis

| Feature            | Finder | Path Finder | Forklift | Commander One | Scout (MVP) |
|--------------------|--------|-------------|----------|---------------|-------------|
| Dual-pane          | --     | Yes         | Yes      | Yes           | Yes         |
| True cut/paste     | --     | Yes         | Yes      | Yes           | Yes         |
| Persistent views   | --     | Yes         | Partial  | Yes           | Yes         |
| Scoped search      | Weak   | Yes         | Partial  | Yes           | Yes         |
| Transfer queue     | --     | --          | Yes      | Yes           | Yes         |
| Workspaces         | --     | --          | --       | --            | Yes         |
| Command palette    | --     | --          | --       | --            | Yes         |
| Terminal built-in  | --     | Yes         | Yes      | Yes           | Yes         |
| Native Swift/AppKit| Yes    | No (Obj-C)  | Partial  | No            | Yes         |
| Price              | Free   | $36         | $30      | $30           | $29         |

Scout's differentiation: Workspaces with session memory, a command palette for discoverability, modern Swift concurrency for performance, and a design philosophy that prioritizes progressive disclosure over feature density.

## 9. MVP Timeline

| Phase       | Focus                                                    | Duration | Milestone              |
|-------------|----------------------------------------------------------|----------|------------------------|
| Alpha 1     | Core file browser, single-pane, navigation, views        | 8 weeks  | Internal dogfood       |
| Alpha 2     | Dual-pane, cut/copy/move, transfer engine                | 6 weeks  | Team daily driver      |
| Alpha 3     | Search, keyboard nav, command palette                    | 6 weeks  | Feature complete       |
| Beta        | Tier 2 features, polish, performance tuning, bug fixes   | 6 weeks  | 500-user closed beta   |
| RC / Launch | Bug fixes, App Store review, launch prep                 | 4 weeks  | Public release         |

Total estimated timeline: ~30 weeks (7.5 months) from project kick-off to public release.

## 10. Business Model

- **Pricing:** $29 one-time purchase (Mac App Store + direct). No subscription for core features.
- **Free trial:** 14-day full-featured trial, no credit card required.
- **Revenue target:** 5,000 paid users in first 6 months post-launch ($145K revenue).
- **Future monetization:** optional Pro upgrade ($15/year) for cloud integrations, plugin API, and priority support.
- **Distribution:** Mac App Store (primary for trust/discoverability) + direct Gumroad/Paddle download (for non-sandboxed version with broader permissions).

## 11. Risks & Mitigations

| Risk                                                 | Likelihood | Mitigation                                                                                                                                              |
|------------------------------------------------------|------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| App Store sandboxing limits file operations           | High       | Offer both sandboxed (App Store) and non-sandboxed (direct) builds. Request Full Disk Access entitlement.                                               |
| Apple improves Finder significantly                   | Low        | History suggests incremental change. Scout's depth (workspaces, command palette, dual-pane) goes well beyond likely Finder updates.                      |
| Performance parity with Finder on large directories   | Medium     | Virtual list rendering from day one. Profile early and often. Use POSIX `getdirentries` for raw speed.                                                  |
| User adoption: switching cost is high                 | Medium     | Default hotkey integration, Finder Sync extension for badge overlays, import Finder sidebar favorites automatically. Frictionless first run.             |
| Crowded market (Path Finder, Forklift, etc.)          | Medium     | Differentiate on design quality, performance, and modern UX (command palette, workspaces). Competitors look dated.                                       |

## 12. Open Questions

1. Should Scout attempt to register as the default file handler (replacing Finder for double-click on folders), or coexist alongside Finder? Replacing Finder is technically complex and fragile.
2. What is the right balance between Mac App Store sandboxing constraints and feature completeness? Some operations (e.g., writing to `/usr/local`, modifying hidden files) require a non-sandboxed build.
3. Should the embedded terminal be a full terminal emulator or a lightweight command runner? Full emulation is complex; a focused "run command here" panel may be more pragmatic for MVP.
4. How should Scout handle iCloud Drive's evicted (cloud-only) files? Finder manages this natively via system APIs, but third-party access may behave differently.
5. Pricing: is $29 one-time the right model, or would $4.99/month attract a larger initial user base? Need user research.

## 13. Appendix: Default Keyboard Shortcuts

| Action                  | Shortcut        |
|-------------------------|-----------------|
| Open Scout (global)     | Opt+Space       |
| Toggle dual-pane        | Cmd+D           |
| New tab                 | Cmd+T           |
| Close tab               | Cmd+W           |
| Switch pane focus        | Tab             |
| Open file/folder        | Enter           |
| Rename                  | F2              |
| Go to parent            | Cmd+Up          |
| Go to path bar          | Cmd+L           |
| Command palette         | Cmd+Shift+P     |
| Cut files               | Cmd+X           |
| Copy files              | Cmd+C           |
| Paste / move files      | Cmd+V           |
| Undo last operation     | Cmd+Z           |
| Search                  | Cmd+F           |
| Toggle preview pane     | Cmd+Shift+Space |
| Quick Look              | Space           |
| Toggle terminal drawer  | `` ` `` (backtick) |
| Copy to other pane      | F5              |
| Move to other pane      | F6              |
| Clipboard history       | Cmd+Shift+V     |
