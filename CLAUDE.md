# CLAUDE.md — Athena

Athena is a **native macOS code editor** built with **Swift 6 + SwiftUI**, targeting **macOS 15 (Sequoia)+**. It is a single-window IDE for fullstack web development: syntax highlighting, integrated terminal, Git, full-text search, LSP, a DAP debugger, npm script runner, Claude AI assistance, and Salesforce Commerce Cloud (SFCC) support.

This file is the contract for working in this repo. Follow it exactly.

---

## Build / Run / Test

Always use the Makefile — it unsets the `GIT_CONFIG_*` env vars that the shell hook injects (SPM uses git internally and breaks without this).

| Task | Command |
|---|---|
| Debug build | `make build-debug` |
| Release build | `make build-release` |
| Run the app | `make run` |
| Run tests | `make test` |
| `.app` bundle | `make` (default) |
| DMG | `make dmg` |
| Clean | `make clean` |

Raw `swift build` / `swift test` work **only** if you prefix `unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0;` first. Prefer the Makefile.

After any non-trivial change: `make build-debug && make test` before reporting done. Never claim a build passes without running it.

---

## Architecture (read before editing)

Single source of truth is **`AppState`** — one `@Observable @MainActor final class` holding all UI state and orchestrating the service actors.

```
Sources/Athena/
├── App/        AthenaApp.swift (@main), AppState.swift (central state)
├── Editor/     NSTextView-based editor (AthenaTextView, EditorView, SyntaxHighlighter,
│               AthenaLayoutManager, MinimapView, GutterView)
├── Models/     SharedTypes.swift (ALL domain types), EditorTheme, KeyBinding, KeyRecorder
├── Services/   actor types — one responsibility each (Git, File, Search, LSP, Claude,
│               SFCC, Debug/DAP, NPMScript, Settings, KeyBinding, ImportResolver, Update…)
├── Commands/   AthenaCommands.swift (menu bar commands)
└── UI/         SwiftUI views — one panel/component per file
```

### Concurrency model — non-negotiable

- **Swift 6 strict concurrency, language mode v6.** Code must compile with zero concurrency warnings.
- **Services are `actor` types.** No shared mutable state; all cross-service work is `async`.
- **`AppState` is `@MainActor`.** All UI state mutation happens on the main thread. UI reads service results via `await`.
- Long-lived async work is stored as `@ObservationIgnored private var task: Task<Void, Never>?` on `AppState` and cancelled on teardown/replacement.
- `@preconcurrency import AppKit` is the established pattern for AppKit interop — match it.
- Domain types in `SharedTypes.swift` are `Sendable` (and `Identifiable`/`Codable`/`Equatable` as needed). Keep them so.

### Editor specifics

- The editor is an **`NSTextView` subclass (`AthenaTextView`)** wrapped in an `NSViewRepresentable` (`EditorView`) — not SwiftUI `TextEditor`. This is deliberate for reliable event interception (mouseDown, link clicks, key handling).
- Editor commands (find, comment, indent, go-to-line…) are dispatched via **`NotificationCenter`** so the keybinding layer reaches the active `NSTextView` without holding a direct reference. Add new editor commands the same way.
- Syntax highlighting is **regex-based, per-language, re-applied after each keystroke** in `SyntaxHighlighter`. Cmd+Click import navigation works by stamping `NSAttributedString.Key.link` attributes on import strings each highlight pass; `textView(_:clickedOnLink:at:)` handles the click.

---

## Conventions

- **File header comment**: 2–3 lines — filename, one-line purpose, `// Swift 6, strict concurrency.` Match existing files.
- **`// MARK: -` sections** to group members (e.g. `// MARK: - Private helper`, `// MARK: - Status`). Use them.
- **Service shape**: `actor FooService`, a typed `enum FooError: Error` for failures, a `private func run(...)` helper for subprocess wrappers using `withCheckedThrowingContinuation` (see `GitService`).
- **External tools** are invoked via `Process` with absolute paths (`/usr/bin/git`, ripgrep, etc.). Capture stdout/stderr via `Pipe`, resume continuation on `terminationHandler`.
- **New domain types** go in `SharedTypes.swift`, not scattered across files. Make them `Sendable`.
- **One view per file** in `UI/`. Keep views thin; push logic into services or `AppState` methods.
- **Settings** persist as individual JSON files in `~/Library/Application Support/Athena/settings/` via `SettingsService`.
- **Keybindings** default to VS Code parity (`KeyBinding.swift`), user-overridable with conflict detection.

## Dependencies (keep minimal)

| Package | Purpose |
|---|---|
| GRDB.swift | SQLite access |
| SwiftTerm | Terminal emulation |

Prefer the platform SDK (AppKit/Foundation/SwiftUI) over adding dependencies. Justify any new package.

## Guardrails

- Do **not** `git push` or create tags without explicit instruction.
- Do not break Swift 6 strict-concurrency compliance to make something compile faster — fix the actor boundary properly.
- This is a native macOS app, not a web app: no Node/npm/React in the editor's own codebase (those exist only as *features the editor supports*, e.g. the npm script runner and LSP for web languages).
- License is proprietary (© Martin Kirilov). Don't add OSS license headers.

## Skills

- `/swift-rockstar` — engage senior Swift 6 / macOS engineering mode for work in this codebase.
- `/macos-web-ide` — product/architecture lens for building IDE features that serve fullstack web developers.
