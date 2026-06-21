# Athena

A native macOS code editor built with Swift 6 and SwiftUI. Athena provides IDE-grade features — syntax highlighting, integrated terminal, Git integration, full-text search, Claude AI assistance, and Salesforce Commerce Cloud support — in a lightweight, single-window app.

**Requires macOS 15 (Sequoia) or later.**

---

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Editor](#editor)
- [Languages](#languages)
- [Sidebar Panels](#sidebar-panels)
- [Bottom Panels](#bottom-panels)
- [Git Integration](#git-integration)
- [Search](#search)
- [Claude AI](#claude-ai)
- [SFCC / Demandware](#sfcc--demandware)
- [Database Connections](#database-connections)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [Themes](#themes)
- [Settings](#settings)
- [Building from Source](#building-from-source)
- [Architecture](#architecture)

---

## Features

| Category | Highlights |
|---|---|
| Editor | Syntax highlighting, minimap, blame annotations, word wrap, Cmd+Click imports |
| Languages | Swift, TypeScript, JavaScript, Python, Rust, Go, JSON, CSS, HTML, ISML, DS, Markdown |
| Version Control | Git status, staging, blame per line |
| Search | Ripgrep-powered workspace search with regex and case-sensitivity |
| Terminal | Fully integrated shell (SwiftTerm) |
| AI | Claude integration — streaming, dual-account (personal + work) |
| SFCC | WebDAV upload-on-save, real-time log tailing |
| Database | Connection manager for PostgreSQL, MongoDB, MySQL, Oracle, MariaDB |
| UI | Resizable panels, customisable keybindings, three built-in themes, UI zoom |

---

## Installation

1. Download the latest `Athena.dmg` from [Releases](https://github.com/martinykiriloff/athena-editor/releases).
2. Open the DMG and drag **Athena.app** to `/Applications`.
3. Launch Athena. On first run, open a folder via **File → Open Folder** (or drag a folder onto the window).

> Athena is not notarised. On first launch, right-click → Open to bypass Gatekeeper.

---

## Editor

### Core

- **NSTextView-based** editor with a custom `AthenaTextView` subclass for reliable event interception.
- **Cmd+Click** on any import/require string navigates to the referenced file (supports relative paths, directory indexes, and common extensions).
- **Middle-click** a tab to close it.
- **Cmd+`=`** / **Cmd+`-`** zoom the entire window UI — sidebar, tabs, status bar, and editor font all scale together.
- **Cmd+`0`** resets zoom.

### Display

| Setting | Default | Notes |
|---|---|---|
| Font family | JetBrains Mono | Any monospaced font installed on the system |
| Font size | 14 pt | Range: 8–48 pt |
| Font ligatures | On | |
| Line height | 1.0× | |
| Word wrap | Off | Per-workspace |
| Line numbers | On | |
| Render whitespace | On | Dots for spaces, arrows for tabs |
| Minimap | On | Click to jump; highlights current viewport |
| Scroll beyond last line | On | |

### Editing

- **Auto-indent** — preserves the indentation level of the previous line.
- **Detect indentation** — infers tabs vs spaces and indent width from the open file.
- **Format on save** — delegates to the active LSP formatter when enabled.
- **Toggle line comment** — `Cmd+/`, uses the correct comment token per language (`//`, `#`, etc.).
- **Indent / Outdent selection** — `Cmd+]` / `Cmd+[`.
- **Go to line** — `Ctrl+G`.
- **Find in file** — `Cmd+F` (native NSTextView find bar).
- **Quick Open** — `Cmd+P` fuzzy-search across all workspace files.

### Blame annotations

Git blame information is fetched lazily and displayed as ghost text to the right of the active line — commit hash, author name, and relative date. The cache is invalidated when the Git status changes.

---

## Languages

Syntax highlighting is regex-based and applied after every keystroke. Each language also receives import-link attributes so Cmd+Click works on any quoted path string on an import/require/from/include line.

| Language | Extensions | Notes |
|---|---|---|
| Swift | `.swift` | |
| TypeScript | `.ts`, `.tsx` | |
| JavaScript | `.js`, `.jsx`, `.mjs` | |
| Python | `.py` | |
| Rust | `.rs` | |
| Go | `.go` | |
| JSON | `.json`, `.jsonc` | |
| CSS | `.css`, `.scss`, `.less` | |
| HTML | `.html`, `.htm` | |
| ISML | `.isml` | Salesforce Commerce Cloud templates |
| DS | `.ds` | Demandware Script (ECMAScript + SFCC APIs) |
| Markdown | `.md`, `.markdown` | |
| Plain text | *(fallback)* | |

### ISML specifics

- ISML tags (`<isif>`, `<iselse>`, `<iselseif>`, `<isloop>`, `<isprint>`, `<isscript>`, `<isinclude>`, `<isset>`, `<isslot>`, `<iscomponent>`, and all other `<is*>` tags) are highlighted in **keyword colour**.
- Standard HTML tags use **function colour**, making ISML tags visually distinct.
- SFCC expression syntax `${...}` is highlighted as a **string**.
- ISML triple-dash comments `<!--- ... --->` are highlighted as **comments** and override any token inside them.

### DS specifics

- Full JavaScript keyword set plus `importPackage`, `importClass`, and `require`.
- `dw.*` package paths (e.g. `dw.catalog.ProductMgr`) are highlighted as **types**.

---

## Sidebar Panels

Toggle the sidebar with **Cmd+B**. Click an icon in the activity bar to switch panels; click the active icon again to hide the sidebar.

### Explorer

File tree for the open workspace. Supports:

- Expand / collapse directories.
- Single-click to open a file in a new tab.
- Right-click context menu: rename, delete.
- Language icon and colour per file type.

### Source Control

Displays the current Git branch and working-tree status:

- **Staged** changes (index).
- **Unstaged** changes (working directory).
- **Untracked** files.
- Ahead/behind commit count relative to the upstream branch.

Files can be staged and unstaged. A commit message field and **Commit** button are available at the bottom of the panel.

Keybinding: **Cmd+Shift+G**.

### Search

Workspace-wide full-text search powered by **ripgrep** (falls back to `grep` if ripgrep is not installed).

- Case-sensitive toggle.
- Regular expression toggle.
- Include / exclude glob filters (comma-separated, e.g. `*.ts, !node_modules`).
- Results grouped by file with line number and content preview.
- Click a result to open the file and jump to the matching line.

Keybinding: **Cmd+Shift+F**.

### Database Connections

Manage and document database connections. Supported engines:

| Engine | Default Port |
|---|---|
| PostgreSQL | 5432 |
| MongoDB | 27017 |
| MySQL | 3306 |
| MariaDB | 3306 |
| Oracle | 1521 |

Connections are persisted in application settings. Each connection stores host, port, database name, username, and password (stored in settings — Keychain migration is planned).

### SFCC Sandboxes

See [SFCC / Demandware](#sfcc--demandware) below.

---

## Bottom Panels

Toggle the bottom panel with **Ctrl+`**. Tabs across the top switch between:

### Terminal

A fully-featured embedded terminal powered by **SwiftTerm**. Launches your default `$SHELL`. Supports colour output, cursor movement, and most terminal escape sequences.

### Problems

Displays LSP diagnostics (errors, warnings, information, hints) grouped by file. Each item shows the message, file name, and line number.

### Output

General-purpose output log for build and command events.

### Claude

Streaming chat interface backed by the Claude CLI. See [Claude AI](#claude-ai).

### SFCC Logs

Real-time log tailing from a connected SFCC sandbox. See [SFCC / Demandware](#sfcc--demandware).

---

## Git Integration

Athena calls standard `git` CLI commands and parses the output:

- `git status --porcelain` for staged/unstaged/untracked file lists.
- `git rev-parse --abbrev-ref HEAD` for the current branch.
- `git rev-list --count HEAD ^@{upstream}` for ahead/behind counts.
- `git blame` for per-line authorship.

Blame results are cached in memory keyed by file path and invalidated when the working tree changes.

---

## Search

Search is powered by **ripgrep** (`rg`) when available, with a `grep -rn` fallback.

Results are streamed asynchronously — the list populates as matches arrive. Searches can be cancelled by clearing the query or switching away from the Search panel.

---

## Claude AI

Athena integrates with Claude through the **Claude CLI** (`claude` / `claude-work`).

### Dual-account support

Two accounts can be configured — **Personal** (`claude`) and **Work** (`claude-work`). Switching accounts aborts any in-flight request and clears the conversation, since each CLI maintains its own session.

### Usage

1. Open the Claude panel with **Cmd+Shift+A** or click the ✦ icon at the bottom of the activity bar.
2. Type a message and press **Return** to send.
3. Responses stream token-by-token into the panel.
4. Use the account chip in the panel header to switch between Personal and Work.

The panel keeps the most recent conversation visible. Each Claude CLI session has full context of the prior exchange up to its context window.

---

## SFCC / Demandware

Athena provides native Salesforce Commerce Cloud integration on par with the [Prophet VS Code extension](https://marketplace.visualstudio.com/items?itemName=SqrTT.prophet).

### Setting up a sandbox connection

1. Click the **cloud** icon in the activity bar to open the **SFCC Sandboxes** panel.
2. Click **+** and fill in:
   - **Connection name** — a label for the sandbox (e.g. "Dev Sandbox").
   - **Hostname** — your sandbox hostname (e.g. `dev01-abc.demandware.net`).
   - **Username / Password** — Business Manager credentials.
   - **Code version** — the active code version (e.g. `version1`).
   - **Cartridges path** — path to the cartridges root relative to the workspace root (e.g. `cartridges`), or an absolute path.
3. Click **Activate** (⚡ icon) on the connection you want to use. Only one sandbox can be active at a time.

### Upload on save

When a sandbox is active, every **Cmd+S** save automatically uploads the file to the sandbox via WebDAV PUT:

```
PUT https://{hostname}/on/demandware.servlet/webdav/Sites/Cartridges/{codeVersion}/{cartridge/...}
```

The cartridge-relative path is computed by stripping the configured cartridges root from the file's absolute path. Files outside the cartridges root are silently skipped.

The status bar shows `↑ SFCC <filename>` on a successful upload.

### Log viewer

Switch to **SFCC Logs** in the bottom panel to tail sandbox logs in real time:

- On open, Athena fetches the list of available log files via WebDAV PROPFIND.
- The error log is auto-selected; use the picker to switch to any other log (requests, custom, fatal, etc.).
- New content is fetched every **3 seconds** using HTTP `Range: bytes=N-` requests — only new bytes are transferred.
- The view auto-scrolls to the bottom as new lines arrive.
- **↺** refreshes the log file list; **🗑** clears the current view.

---

## Database Connections

The Database panel is a connection manager. Add a connection with the **+** button, providing:

- **Name**, **Engine type**, **Host**, **Port**, **Database**, **Username**, **Password**.

Connections are persisted in application settings. Active query execution is planned for a future release.

---

## Keyboard Shortcuts

All shortcuts use VS Code defaults and are fully customisable via **Settings → Keybindings**.

### File

| Action | Shortcut |
|---|---|
| New file | `Cmd+N` |
| Save file | `Cmd+S` |
| Close tab | `Cmd+W` |
| Quick Open | `Cmd+P` |

### Navigation

| Action | Shortcut |
|---|---|
| Go to line | `Ctrl+G` |
| Next tab | `Ctrl+Tab` |
| Previous tab | `Ctrl+Shift+Tab` |

### View

| Action | Shortcut |
|---|---|
| Toggle sidebar | `Cmd+B` |
| Toggle terminal | `Ctrl+`` |
| Show Explorer | `Cmd+Shift+E` |
| Show Source Control | `Cmd+Shift+G` |
| Show Search | `Cmd+Shift+F` |
| Show Claude panel | `Cmd+Shift+A` |
| Zoom in | `Cmd+=` |
| Zoom out | `Cmd+-` |
| Reset zoom | `Cmd+0` |

### Editor

| Action | Shortcut |
|---|---|
| Find in file | `Cmd+F` |
| Toggle line comment | `Cmd+/` |
| Indent | `Cmd+]` |
| Outdent | `Cmd+[` |

### Tabs

| Action | How |
|---|---|
| Close tab | Middle-click (scroll-wheel click) |
| Switch tab | Left-click |

---

## Themes

Three themes are built in. Switch via **Settings → Appearance**.

### Darcula *(default)*

Dark theme based on the JetBrains IDE default. High-contrast keywords on a near-black background.

### One Dark

Atom-inspired dark theme with muted, earthy accent colours.

### GitHub Light

Light theme matching GitHub's web editor colour palette.

Each theme defines colours for: background, foreground, cursor, selection, current-line highlight, keyword, string, number, comment, type, function, annotation, and whitespace indicator.

---

## Settings

Settings are persisted as individual JSON files in:

```
~/Library/Application Support/Athena/settings/
```

Open the Settings window via the gear icon at the bottom of the activity bar, or by pressing `Cmd+,`.

Available settings panels:

- **Editor** — font, size, ligatures, line height, tab size, spaces vs tabs, word wrap, line numbers, whitespace, minimap, scroll beyond last line, format on save, auto-indent, detect indentation, cursor style and blink.
- **Appearance** — theme selection.
- **Keybindings** — full keybinding editor with conflict detection and reset to defaults.

The last opened workspace path is restored on relaunch.

---

## Building from Source

### Requirements

- macOS 15+
- Xcode 16+ **or** Swift 6 toolchain (`swift --version` should report `6.x`)

### Steps

```bash
git clone https://github.com/martinykiriloff/athena-editor.git
cd athena-editor
swift build -c release
```

To run directly:

```bash
swift run
```

To produce an `.app` bundle and DMG:

```bash
swift build -c release

mkdir -p Athena.app/Contents/MacOS Athena.app/Contents/Resources
cp .build/release/Athena   Athena.app/Contents/MacOS/Athena
cp XcodeConfig/Info.plist  Athena.app/Contents/Info.plist
cp XcodeConfig/AppIcon.icns Athena.app/Contents/Resources/AppIcon.icns

hdiutil create -volname "Athena" -srcfolder Athena.app -ov -format UDZO Athena.dmg
```

### Dependencies

| Package | Version | Purpose |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 6.0.0+ | SQLite access |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.2.0+ | Terminal emulation |

---

## Architecture

Athena is structured around a single `@Observable @MainActor` class, `AppState`, which holds all UI state and coordinates between services.

```
Sources/Athena/
├── App/
│   ├── AthenaApp.swift          # @main entry point, window configuration
│   └── AppState.swift           # Central observable state (~650 lines)
├── Editor/
│   ├── AthenaTextView.swift     # NSTextView subclass (mouseDown, link interception)
│   ├── EditorView.swift         # NSViewRepresentable wrapping NSScrollView + AthenaTextView
│   ├── SyntaxHighlighter.swift  # Regex-based per-language tokeniser
│   ├── AthenaLayoutManager.swift # Custom NSLayoutManager (whitespace rendering)
│   └── MinimapView.swift        # Minimap NSView
├── Models/
│   ├── SharedTypes.swift        # All domain types (Language, panels, Git, DB, SFCC…)
│   ├── EditorTheme.swift        # Theme colour definitions
│   ├── KeyBinding.swift         # Keybinding model & VS Code defaults
│   └── KeyRecorder.swift        # NSViewRepresentable for capturing key combos
├── Services/
│   ├── FileService.swift        # File I/O, directory tree
│   ├── GitService.swift         # git CLI wrapper
│   ├── GitBlameService.swift    # Blame cache
│   ├── ClaudeService.swift      # Anthropic API (SSE streaming)
│   ├── ClaudeCLIService.swift   # Claude CLI subprocess
│   ├── SearchService.swift      # ripgrep / grep
│   ├── LSPManager.swift         # Language Server Protocol (JSON-RPC 2.0)
│   ├── KeyBindingService.swift  # Persistent keybindings
│   ├── SettingsService.swift    # JSON settings persistence
│   ├── ImportResolver.swift     # Cmd+Click import path resolution
│   ├── SFCCService.swift        # WebDAV upload + log tailing
│   └── UpdateService.swift      # Auto-update checking
└── UI/
    ├── MainWindowView.swift     # Root layout (activity bar | sidebar | editor | Claude panel)
    ├── ActivityBarView.swift    # Left icon strip
    ├── SidebarView.swift        # Sidebar container / router
    ├── TabBarView.swift         # Tab bar with middle-click-to-close
    ├── FileTreeView.swift       # Explorer panel
    ├── GitPanelView.swift       # Source control panel
    ├── SearchPanelView.swift    # Search panel
    ├── DBConnectionsView.swift  # Database connections panel
    ├── SFCCSidebarView.swift    # SFCC sandboxes panel
    ├── BottomPanelView.swift    # Bottom panel container + Problems + Output
    ├── SFCCLogView.swift        # SFCC log viewer (bottom panel)
    ├── TerminalView.swift       # SwiftTerm wrapper
    ├── ClaudePanel.swift        # Claude AI right panel
    ├── ChatView.swift           # Legacy chat view
    ├── StatusBarView.swift      # Status bar
    ├── WelcomeView.swift        # No-workspace landing screen
    ├── QuickOpenView.swift      # Cmd+P file picker overlay
    └── SettingsView.swift       # Settings window
```

### Concurrency model

- All services are Swift `actor` types — no shared mutable state.
- `AppState` lives on `@MainActor`; all UI mutations happen on the main thread.
- Editor commands (find, comment, indent…) are dispatched through `NotificationCenter` so the keybinding system can reach the active `NSTextView` without a direct reference.
- Cmd+Click import navigation uses `NSAttributedString.Key.link` attributes stamped on import strings after each highlight pass; `textView(_:clickedOnLink:at:)` fires natively on Cmd+Click in editable NSTextViews.

---

## License

© 2025 Martin Kirilov. All rights reserved.
