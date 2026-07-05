# Athena vs VS Code — Gap Analysis & Implementation Plan

Audience: fullstack web developer on macOS. Strategy: **VS Code parity where it builds muscle memory, native speed as the moat.** This is not a plan to clone VS Code — it's a plan to close the gaps that break a web dev's inner loop (edit → save → see result), ranked by how often a user hits each gap per hour of work.

Snapshot of what Athena already has: regex syntax highlighting (13 languages incl. ISML/DS), Cmd+P quick open, find-in-file, go-to-line, toggle comment, minimap, inline git blame, ghost-text AI completion (Claude/Ollama), completion popup (Drizzle + LSP plumbing), git stage/commit/push/pull, ripgrep workspace search, DAP + CDP debugging (Node/Chrome/Next.js/Python/Swift), SwiftTerm terminal, npm script runner, Claude chat + Claude Code CLI panel, SFCC WebDAV sync + log tail, VS Code-parity keybindings (rebindable), auto-update.

---

## Part 1 — Gap list vs VS Code

Status legend: **Broken/dormant** = code exists but doesn't work · **Partial** = works with major limitations · **Missing** = not present.

### A. Language intelligence (worst area — highest impact)

| # | Feature | VS Code | Athena | Status |
|---|---|---|---|---|
| A1 | LSP server lifecycle | Automatic per language | `LSPManager.startServer` is **never called** — completions/hover dead in practice | **Broken/dormant** |
| A2 | Diagnostics (squiggles + Problems panel) | Live via LSP `publishDiagnostics` | `AppState.diagnostics` is never written; Problems panel always empty | **Broken/dormant** |
| A3 | Go to Definition / Peek | F12 / ⌥F12 | Cmd+Click resolves **import paths only** (`ImportResolver`), no symbol-level defs | Missing |
| A4 | Hover tooltips | Type info + docs on hover | `LSPManager.hover()` exists, no UI wired | **Broken/dormant** |
| A5 | Find All References | ⇧F12 | — | Missing |
| A6 | Rename Symbol | F2, cross-file | — | Missing |
| A7 | Format document / format-on-save | Built-in + Prettier | Settings flag exists, **no implementation** | Broken/dormant |
| A8 | Go to Symbol (⇧⌘O) / Outline view / breadcrumbs | Yes | — | Missing |
| A9 | Signature help, code actions / quick fixes | Yes | — | Missing |
| A10 | Semantic/tree-sitter highlighting | Semantic tokens | Regex re-run per keystroke (accuracy + perf ceiling on large files) | Partial |

### B. Core editing

| # | Feature | VS Code | Athena | Status |
|---|---|---|---|---|
| B1 | Multiple cursors / multi-select (⌥Click, ⌘D) | Yes | — | Missing |
| B2 | Auto-closing brackets/quotes + bracket-pair matching | Yes | — | Missing |
| B3 | Auto-indent on newline | Yes | Settings flag stored, not implemented | Broken/dormant |
| B4 | Find **& Replace** in file | ⌥⌘F | Find only (NSTextFinder bar) | Partial |
| B5 | Snippets with tab stops | Yes | Drizzle inserts are literal text | Missing |
| B6 | Code folding | Yes | — | Missing |
| B7 | Move/copy line up/down, duplicate line | ⌥↑/⌥↓ etc. | — | Missing |
| B8 | Sticky scroll | Yes | — | Missing |

### C. Workbench & navigation

| # | Feature | VS Code | Athena | Status |
|---|---|---|---|---|
| C1 | **Command palette** (⇧⌘P) | Core motion | Not implemented (Welcome screen even advertises it) | Missing |
| C2 | Split editors / editor groups | Yes | Single editor pane | Missing |
| C3 | Session restore (reopen tabs on launch) | Yes | Restores workspace only; **tabs lost** | Partial |
| C4 | External file-change detection | File watcher, auto-reload | **None** — no FS events; stale buffers possible | Missing |
| C5 | Tab drag-reorder; file-tree drag & drop | Yes | — | Missing |
| C6 | Search & Replace across workspace | Yes | Search only | Partial |
| C7 | Markdown preview; image preview | Yes | — | Missing |
| C8 | Zen mode / centered layout | Yes | — | Missing |
| C9 | Theme ecosystem | Thousands, importable | 3 fixed built-ins | Partial |

### D. Git

| # | Feature | VS Code | Athena | Status |
|---|---|---|---|---|
| D1 | Discard changes | Yes | **Bug: runs `git diff` and discards the output — file is never reverted** | Broken |
| D2 | Diff viewer (side-by-side/inline) | Core | Service can produce diffs; no viewer UI | Missing |
| D3 | Branch switcher UI (status-bar picker) | Yes | Service has branches/checkout; no UI | Missing |
| D4 | Gutter change indicators | Yes | — | Missing |
| D5 | Merge-conflict resolution UI | Yes | — | Missing |
| D6 | Stash, commit-history browser, clone repo | Yes | Clone is a Welcome-screen placeholder; no stash; `log` unused by UI | Missing |

### E. Terminal, tasks, debug

| # | Feature | VS Code | Athena | Status |
|---|---|---|---|---|
| E1 | Multiple terminals / tabs / split | Yes | Single terminal instance | Partial |
| E2 | Watch expressions, conditional breakpoints, logpoints | Yes | Plain breakpoints only | Partial |
| E3 | Debug console REPL (evaluate in frame) | Yes | Output view only, no input | Partial |
| E4 | Hover-to-inspect variables while paused | Yes | — | Missing |
| E5 | tasks.json / generic task runner | Yes | npm scripts only (fine for target user; low priority) | Partial |

### F. Deliberate non-goals (don't build)

- **Extension marketplace** — Athena's bet is native, integrated, fast. Ship the top extensions' *functionality* built-in (Prettier, GitLens-style blame ✓ already, themes) instead of an extension host.
- **Remote development / SSH / containers, Live Share, notebooks, Settings Sync, profiles, web version.** Wrong fights for a native single-window macOS IDE.
- Athena-specific surfaces VS Code lacks (SFCC sync/logs, Claude panels, DB connection manager) are differentiators — out of scope here, except one note: the DB panel has **no query execution** (GRDB is an unused dependency). Either ship a minimal query runner or hide the panel until it's real; a connect toggle that does nothing erodes trust.

---

## Part 2 — Implementation plan

Ordered by inner-loop impact ÷ effort. Each phase is shippable on its own. Effort: S ≤ 1 day, M ≈ 2–4 days, L ≈ 1–2 weeks.

### Phase 0 — Fix what's already built but dead (1 week, mostly S) — ✅ DONE (2026-07-04)

The highest-ROI work in the repo: three subsystems are ~80% built and 0% functional.

1. ✅ **Wire the LSP lifecycle (A1)** — M
   - In `AppState`, on workspace open / first file of a language: `await lspManager.startServer(for: language, workspaceRoot:)`. Send `textDocument/didOpen` on tab open, `didChange` on edit (already exists, never called), `didClose`/`shutdown` on teardown.
   - Store server tasks as `@ObservationIgnored` tasks per the concurrency contract; cancel on workspace close.
   - Smallest slice: TS/JS only (`typescript-language-server`), completions actually appearing. Then flip on pylsp/gopls/rust-analyzer/sourcekit-lsp — the launch code already exists.
2. ✅ **Diagnostics pipeline (A2)** — M
   - Handle `textDocument/publishDiagnostics` notifications in `LSPManager`, expose an `AsyncStream<[Diagnostic]>`, consume it in `AppState.diagnostics`. Problems panel and status-bar counters light up with **zero UI work** — they're already built.
3. ✅ **Fix Git "Discard Changes" (D1)** — S
   - Replace the `diff` call with `git restore --worktree --` (or `checkout --` pre-2.23). Add a confirmation dialog — it's destructive. Add `restore` to `GitService`.
4. ✅ **Honor dead settings or remove them (A7, B3)** — S for removal decision; implementation lands in Phases 1–2 below. Ship auto-indent-on-newline now (S): on `insertNewline`, copy previous line's leading whitespace; +1 indent level after `{`, `(`, `[`, `:`.

**Exit criteria:** typing in a `.ts` file shows real LSP completions; a type error shows in Problems + status bar; Discard Changes actually reverts.

**Implementation notes:**
- `LSPManager`: added `didOpen`/`didClose`/`stopAllServers`/`diagnosticsStream()`; `readLoop()` now branches on JSON-RPC notifications (no `id`) vs request responses, parsing `textDocument/publishDiagnostics` (LSP severity 1–4 → `DiagnosticSeverity`, 0-based line/character → this app's 1-based convention).
- `AppState`: `openFile` starts the server + sends `didOpen`; `updateTabContent` fires `didChange`; `closeTab` sends `didClose` + clears that file's diagnostics; `openWorkspace`/`closeFolder` **await** `lspManager.stopAllServers()` before proceeding (a first-pass version used an unawaited `Task { }` here, which the verify pass caught as a stale-server-across-workspace-switch race — fixed by awaiting inline and converting `closeFolder()` to `async`, with its `MainWindowView.swift` call site updated to `Task { await appState.closeFolder() }`). Added `discardChanges(path:)`: real `GitService.restore` (`git checkout -- <path>`), refreshes git status, and reloads any open tab for that file directly from disk (bypassing `updateTabContent` so it doesn't re-mark dirty or re-fire `didChange`).
- `GitPanelView`: "Discard Changes" now shows a confirmation alert (matching `FileTreeView`'s delete-confirmation pattern) before calling `appState.discardChanges(path:)`.
- `EditorView`: `autoIndent` threaded through from `appState.editorAutoIndent`; Return key copies leading whitespace and adds one indent unit after `{`/`(`/`[`/`:`, respecting tab size / spaces-vs-tabs.
- Side fix: `make test` was failing in this dev environment with "no such module 'Testing'" (Xcode Command Line Tools only, no full Xcode.app). Root-caused and fixed in the `Makefile` (detects CLT-only installs and passes the right `-F`/`-rpath` flags to `swift test` so swift-testing resolves) rather than left as an accepted gap.
- Verified independently (build + all 22 tests) after the workflow completed — both green.
- Known minor rough edges intentionally left for later phases: `didChange` fires unthrottled on every keystroke (no debounce/coalescing — a perf nit, not a correctness bug); auto-indent only inspects the single character immediately before the cursor (doesn't skip trailing whitespace); "Discard Changes" is still offered for untracked ("?") files where `git checkout --` harmlessly no-ops instead of deleting.

### Phase 1 — Muscle-memory parity (2–3 weeks)

5. ✅ **Command palette ⇧⌘P (C1)** — M — DONE (2026-07-04)
   - Reuse `QuickOpenView`'s window/list/ranking; back it with a command registry derived from the existing `KeyBinding` table + `AppState.perform(_:)` actions so every command shows its keybinding. `>` prefix in Cmd+P switches modes, matching VS Code.

   **Implementation notes:**
   - `KeyBinding.swift`: added `KeyAction.commandPalette` (`"workbench.action.showCommands"`), display name "Command Palette", grouped into the existing "Navigation" category alongside `.quickOpen`; added its VS Code default `KeyBinding(action: .commandPalette, combo: KeyCombo(key: "p", command: true, shift: true))` (⇧⌘P) to `KeyBinding.vscodeDefaults`. No new `SharedTypes.swift` type needed — reused `KeyBinding`/`KeyCombo` as-is.
   - `AppState.swift`: extended the existing quick-open state instead of adding a parallel `showCommandPalette` bool — added `var quickOpenPrefill: String = ""`, and `presentQuickOpen(prefill:)` now seeds it ("" for `.quickOpen`, ">" for `.commandPalette`) before setting `showQuickOpen = true`. `perform(_:)` gained `case .commandPalette: presentQuickOpen(prefill: ">")`; dispatch reaches it through the same `dispatchKeyInfo` → `perform` path already used by every other binding (no key-monitor changes needed).
   - `QuickOpenView.swift`: made mode-aware rather than adding a sibling view, so the two palettes share one visual system. `isCommandMode` = `query.hasPrefix(">")`; `.onAppear` seeds local `@State query` from `appState.quickOpenPrefill`. In command mode the list source switches to `appState.keyBindings` (the **effective**, override-aware bindings loaded by `KeyBindingService`/`installKeyMonitor`, not the raw `vscodeDefaults`) filtered by substring match against `action.displayName` with prefix-match ranked first (mirrors the existing file-search ranking). Added `CommandPaletteRow` (same padding/selection-highlight chrome as `QuickOpenRow`) showing displayName + category + the binding's `combo.displayString` (blank if unbound). Return invokes `Task { await appState.perform(action) }` then closes, matching how the key monitor itself dispatches. Arrow-key nav/auto-scroll/Escape all reused via a shared `currentResultCount`/`move`/`confirmSelection` that branch on `isCommandMode`.
   - `AthenaCommands.swift`: added a "Command Palette…" item to the Go menu (`performAction(.commandPalette)`), matching the existing "Go to File…" wiring pattern, for menu-bar discoverability.
   - Welcome screen's "⇧⌘P Command Palette" cheat-sheet entry now does something.
   - Verified: `make build-debug` zero warnings/errors; `make test` — all 22 tests still pass (no new tests added — this is a UI-wiring change over existing, already-tested `perform(_:)`/`KeyBindingService` logic, not new business logic).
6. ✅ **File watching (C4)** — M — DONE (2026-07-05)
   - New `actor FileWatchService` on `FSEventStream` (or `DispatchSource` per open file). Auto-refresh file tree; for open tabs: silently reload if not dirty, show "file changed on disk" bar if dirty. This prevents silent data loss — arguably Phase 0 severity.

   **Implementation notes:**
   - `FileWatchService.swift` (new): per-open-file + workspace-root `DispatchSource.makeFileSystemObjectSource` watching (`O_EVTONLY` fd, `.write`/`.delete`/`.rename` for files, `.write` for the root directory) — no new dependency, pure Foundation/Dispatch, per the task's scoped-down alternative to a full FSEvents tree watch. Single-subscriber `eventStream() -> AsyncStream<FileWatchEvent>` mirrors `LSPManager.diagnosticsStream()`'s continuation-storage pattern exactly. Event handlers capture only `[weak self]` + the `Sendable` `URL` (not the non-`Sendable` `DispatchSourceFileSystemObject`) and look the watch back up inside the actor to read `.data`, avoiding any actor-boundary Sendability issue.
   - `SharedTypes.swift`: added `FileWatchEvent` enum (`.fileChanged`/`.fileDeleted`/`.directoryChanged`, both `Sendable` + `Equatable`) and `TabModel.externallyModified: Bool`.
   - `AppState`: `fileWatchService` added to the service list (constructor-injectable, default `FileWatchService()`); `startFileWatchConsumer()` (called once from `AthenaApp.swift` alongside `startDiagnosticsConsumer()`) subscribes for the app's lifetime. Lifecycle wiring mirrors `LSPManager`'s per-language servers: `openFile` → `watchFile`, `closeTab` → `stopWatchingFile`, `openWorkspace` → `watchDirectory` (replaces any prior root watch), `closeFolder` → `stopAll()`; `saveActiveTabAs` re-points the watch from the old path to the new one so repeated Save-As doesn't leak descriptors.
   - Directory events debounce 300 ms (`fileTreeRebuildTask`, cancel-and-reschedule) before calling `fileService.buildFileTree` again, so a burst (git pull, `npm install`) causes one rebuild, not one per touched file — matches the existing full-tree-replace behavior `FileTreeView` already does after its own create/delete/rename actions (expansion state isn't preserved today either way).
   - File-change events: if the tab isn't dirty, reload its content directly from disk (`fileService.readFile`, set `content`/`isDirty` directly — the exact same bypass-`updateTabContent` pattern `discardChanges(path:)` already uses, so it doesn't re-mark dirty or re-fire LSP `didChange`); if the tab is dirty, set `TabModel.externallyModified = true` instead of clobbering it.
   - Delete/rename events are disambiguated in `AppState` rather than trusted at face value: `DispatchSource` reports "gone" identically for a real delete and for an atomic-save tool (`git checkout`, many editors) that writes a temp file and renames it over the original — indistinguishable at the fd level once the descriptor stops resolving. `handleExternalFileRemoval` checks whether the path still exists; if it does, it re-arms the watch (the service already tore down the stale one) and treats it as an ordinary content change instead of a false "deleted" banner. Only a genuinely missing path calls `markFileOrphaned`, which forces the tab dirty and posts a `statusMessage` ("saved to recreate it") per the task's "status message is sufficient signaling for this pass" scope.
   - UI: `EditorContainerView.swift` gained `ExternalChangeBanner` — a warning-tinted bar (same `HStack`/height/`.overlay(alignment: .bottom) { Divider() }` chrome as `DebugToolbarView`) shown above the editor when the active tab's `externallyModified` is set, with "Reload" (`appState.reloadTabFromDisk`) and "Keep My Changes" (`appState.keepLocalChanges`) actions.
   - Every other path that resyncs a tab with disk (`saveActiveTab`, `saveAllTabs`, `saveActiveTabAs`, `revertActiveTab`, `discardChanges`) also clears `externallyModified` now, so a normal save/revert/discard doesn't leave a stale banner showing.
   - New test suite `FileWatchServiceTests` (4 tests: watched-file write → `.fileChanged`, watched-file delete → `.fileDeleted`, `stopWatchingFile` silences further events, watched-directory entry → `.directoryChanged`) using a polling `waitUntil` helper (bounded, non-flaky) instead of a fixed `sleep`; total suite now 26 tests, all green, verified stable across repeated runs.
7. ✅ **Find & Replace, in-file and workspace (B4, C6)** — M — DONE (2026-07-05)
   - In-file: custom find bar (NSTextFinder replace is clunky) with replace/replace-all, regex, case, whole-word.
   - Workspace: add replace field to `SearchPanelView`; preview per-match, apply via `FileService` batched writes. Ripgrep already yields file/line/range.

   **Implementation notes:**
   - `SharedTypes.swift`: added `TextSearchMatcher` (in the existing "Search" section, next to `SearchResult`) — a single `Sendable` literal/regex match-and-replace engine (`matches(in:)`, `replacementText(forMatchIn:range:replacement:)` honoring `$1`-style regex capture groups, `replacingAll(in:with:)` applying back-to-front so earlier ranges stay valid) shared by both the in-file bar and the workspace replace, so case-sensitivity/whole-word/regex semantics can't drift between the two surfaces. Whole-word wraps the (escaped, if literal) pattern in `\b(?:…)\b`; literal-mode replacement text is run through `NSRegularExpression.escapedTemplate(for:)` so a literal `$1` in the replacement field is never misread as a capture reference. Also added `EditorCommand.findAndReplace`.
   - `KeyBinding.swift`: added `KeyAction.findAndReplace` (`"editor.action.startFindReplaceAction"`, VS Code's own command id), category "Editor", default binding ⌥⌘F (`KeyCombo(key: "f", command: true, option: true)`) alongside the existing ⌘F `.findInFile`.
   - `AppState.perform(_:)`: `.findAndReplace` forwards to `postEditorCommand(.findAndReplace)`, identical dispatch path to `.findInFile`. New `replaceAllInWorkspace(query:replacement:regex:caseSensitive:wholeWord:filter:)` (new "Workspace Search & Replace" section): re-runs `SearchService.search` itself (rather than trusting the panel's possibly-stale `searchResults`) to get the current file list, applies `TextSearchMatcher.replacingAll` per file, writes changed files via `fileService.writeFile` (never ripgrep's own `--replace`, so results stay consistent with how the rest of the app writes files), and — for any file that's also an open tab — sets `content`/`isDirty = false`/`externallyModified = false` directly, the same bypass-`updateTabContent` pattern `discardChanges(path:)` and the FileWatchService reload path already use. Publishes a `statusMessage` summary ("Replaced N occurrences across M files" / "No occurrences of … found") since a workspace-wide bulk replace is destructive enough to want visible confirmation, without a blocking modal.
   - `Editor/FindReplaceController.swift` (new): `@Observable @MainActor final class` owning the in-file bar's state (query/replacement/regex/case/whole-word toggles, `matches: [NSRange]`, `currentMatchIndex`, `isVisible`/`showReplace`) and a `weak var textView: NSTextView?`, created and wired in `EditorView.makeNSView` exactly like the existing `EditorScrollProxy` (constructed once, handed out via a `Binding<FindReplaceController?>?` parameter, and also stashed on the `Coordinator` for internal notification handling). Matches are highlighted via `NSLayoutManager.addTemporaryAttribute(.backgroundColor, …)` (current match `NSColor.findHighlightColor`, others at 35% alpha) rather than `NSTextStorage` attributes, so highlighting can't be clobbered by — or clobber — `SyntaxHighlighter`'s per-keystroke `setAttributedString` and never touches the undo stack. `replaceCurrent()`/`replaceAll()` go through the identical `shouldChangeText`/`replaceCharacters`/`didChangeText` undo-aware path `EditorView.Coordinator.replace(_:with:in:)` already uses, so edits group into undo correctly and fire `textDidChange` (keeping the bound tab content and highlighting in sync). Deliberately uses plain stored properties (no `didSet`) with the SwiftUI view calling `updateMatches()` explicitly on every change — mirrors `SearchPanelView`'s existing `.onChange(of:) { … }` pattern rather than relying on `@Observable` + property-observer interaction, which has no precedent elsewhere in the codebase.
   - `EditorView.swift`: replaced the `NSTextFinder`-based `showFindBar` (`tv.performTextFinderAction(.showFindInterface)`) entirely — `.find`/`.findAndReplace` now call `findReplaceController?.present(withReplace:)`. `Coordinator.handle(_:)` no longer requires the text view to be `firstResponder` for find commands specifically (only for `.goToLine`/`.toggleComment`/`.indent`/`.outdent`), since ⌘F/⌥⌘F must still reach the editor even when focus is already inside the bar's own search field or in the terminal, matching VS Code. Escape (`handleKeyDown` case 53) now also dismisses the bar (after completion popup / ghost text, in that priority order).
   - `UI/FindReplaceBarView.swift` (new): floating SwiftUI bar (`@Bindable var controller: FindReplaceController`), overlaid `.topTrailing` on the editor in `EditorContainerView.CodeEditorView` (a new `@State private var findReplaceController: FindReplaceController?` threaded through the same `Binding` pattern as `scrollProxy`). Toggle buttons for regex/case/whole-word reuse `SearchPanelView`'s existing visual language (monospaced glyph, accent-tinted when on) for consistency. A `focusRequestToken` on the controller (bumped every `present` call) lets the bar refocus its query field even when re-invoked while already visible (e.g. ⌥⌘F pressed again while the replace field has focus) — `onAppear` alone only fires once per mount.
   - `AthenaCommands.swift`: added a "Find" menu (`Find…` / `Find and Replace…`) mirroring the Go menu's `performAction(...)` wiring, for menu-bar discoverability — no such menu existed before this.
   - `SearchPanelView.swift`: added a disclosure chevron (left of the magnifying glass, VS Code's placement) toggling a new replace row (replacement field + "Replace All" button, disabled when there are no current results) below the search bar. "Replace All" calls the new `AppState.replaceAllInWorkspace` with the panel's existing regex/case toggles and include/exclude filter, then re-runs `triggerSearch()` so the results list reflects the new file contents; the button's tooltip states the exact scope ("Replace N occurrences across M files") as the "before" visibility the task asked for, with the `statusMessage` summary serving as the "after".
   - New test suite `TextSearchMatcherTests` (12 tests: case-insensitive/case-sensitive literal matching, whole-word boundary exclusion, regex special chars treated literally in non-regex mode, regex pattern matching, invalid-regex and empty-query init failures, `replacingAll` counts/no-op/capture-group templating, literal-mode replacement never treating `$1` as a template, single-match `replacementText` capture groups) — total suite now 38 tests. All green on repeated `make build-debug` (zero warnings) + `make test` runs; one pre-existing, unrelated flake was observed in `FileWatchServiceTests` (Phase 1 item 6, untouched by this change) on ~2 of 8 `make test` invocations during this work — a DispatchSource-timing sensitivity worth a separate look, not introduced here.
   - Verify pass: build/tests green throughout; could not obtain an on-screen screenshot of the bar in this sandbox (`screencapture`/`osascript System Events` both denied by TCC — Screen Recording/Accessibility not authorized for this shell's execution context, confirmed via a read-only TCC.db probe that was itself denied). The app process does launch and stay resident under the real binary path (`.build/debug/Contents/MacOS/Athena` — note `make run`'s `.build/debug/$(APP_NAME)` path is currently a directory, not the executable, on this machine; a separate Makefile nit, not fixed here). Manual on-screen confirmation of the bar's rendering/interaction is still outstanding.
8. **Auto-closing brackets + pair highlight (B2)** — S/M — `AthenaTextView.insertText` interception; skip-over on typing the closing char; highlight matching bracket at caret.
9. **Session restore (C3)** — S — persist open tabs + active tab + scroll/cursor per workspace via `SettingsService` JSON keyed by workspace path; restore in `restoreLastWorkspace`.
10. **Go to Definition + hover UI (A3, A4)** — M
    - `textDocument/definition` in `LSPManager`; route Cmd+Click through LSP first, `ImportResolver` as fallback. Hover: floating NSPanel after 500 ms dwell, rendering the already-parsed hover contents.

**Exit criteria:** a VS Code user's hands work unchanged: ⇧⌘P, ⌘P, ⌥⌘F, F12/Cmd+Click, and no stale-file surprises.

### Phase 2 — Editing power (3–4 weeks)

11. **Multiple cursors (B1)** — L — `NSTextView` supports `selectedRanges`; implement ⌥Click add-caret, ⌘D select-next-occurrence, ⇧⌥drag column select, multi-range typing/paste. Hardest single item in the plan; ship ⌘D first (80% of usage).
12. **Format-on-save (A7)** — M — LSP `textDocument/formatting` first; fall back to project-local Prettier (`node_modules/.bin/prettier`) via `Process` for the web languages — reads the project's own config, matching "meet projects where they are."
13. **Rename symbol + references (A5, A6)** — M — LSP `rename` returns a `WorkspaceEdit`; apply across open/closed files via `FileService`; references list reuses search-results UI.
14. **Go to Symbol / outline / breadcrumbs (A8)** — M — LSP `documentSymbol`; ⇧⌘O palette mode reuses command-palette infra; breadcrumbs bar above editor from the same data.
15. **Inline diagnostic squiggles (A2 finish)** — S/M — `AthenaLayoutManager` already does custom drawing (whitespace glyphs); add underline drawing for diagnostic ranges + gutter markers.
16. **Snippets with tab stops (B5)** — M — minimal engine: `$1`, `$2`, `${1:placeholder}`, Tab cycles. Upgrade Drizzle completions to use it; add user snippets JSON later.
17. **Line ops (B7)** — S — move/duplicate/delete line keybindings; pure text manipulation, quick win alongside B1.

### Phase 3 — Workbench: git depth, splits, terminals (3–4 weeks)

18. **Diff viewer (D2)** — L — side-by-side scrolling-synced read-only editors with change highlighting; entry points: git panel file click, gutter indicator click. Smallest slice: unified inline diff rendered with existing highlighter.
19. **Git gutter indicators (D4)** — S/M — `git diff` per open file (debounced on save) → colored bars in `GutterView` (added/modified/deleted).
20. **Branch switcher + clone + history (D3, D6)** — M — status-bar branch menu (list/checkout/create — service methods exist); implement the Welcome screen's Clone Repository; commit-history list using existing `log`.
21. **Multiple terminals (E1)** — M — tab strip inside the terminal panel; `TerminalView` already encapsulates one SwiftTerm instance; add split later.
22. **Split editors (C2)** — L — two editor groups side-by-side first (not arbitrary grids); tab model becomes per-group. Do after tabs gain drag-reorder (C5, S) since both touch `TabBarView`/tab state.
23. **Merge-conflict UI (D5)** — M — detect conflict markers, render Accept Current/Incoming/Both buttons above each hunk.

### Phase 4 — Debug depth & polish (2–3 weeks, opportunistic)

24. **Debug: watch expressions + REPL input + conditional breakpoints (E2, E3)** — M — DAP `evaluate` and `setBreakpoints` with conditions are protocol-supported already; add UI in `DebugSidebarView` + input row in Output.
25. **Hover-to-inspect while paused (E4)** — S/M — reuse hover panel from Phase 1 with DAP `evaluate` in the selected frame.
26. **Markdown + image preview (C7)** — S/M — WKWebView-rendered markdown split preview; NSImage view for image files (currently they open as garbled text).
27. **VS Code theme import (C9)** — M — map VS Code theme JSON token colors onto `EditorTheme`; instantly hundreds of themes with zero design work.
28. **Sticky scroll, zen mode (B8, C8)** — M — nice-to-haves once symbols (A8) exist.

### Dependency notes

- A1 (LSP lifecycle) unblocks A2→A9 and item 12 — do first, everything intelligence-related hangs off it.
- Command palette infra (item 5) is reused by ⇧⌘O (14) — build the palette as a generic mode-based picker.
- Diagnostics stream (item 2) before squiggles (15).
- Tab drag-reorder (C5) before split editors (22).
- No new dependencies required for any Phase 0–2 item; Phase 3–4 also fits AppKit/Foundation. Keep the dep list at GRDB + SwiftTerm.

### Suggested order of attack (first two weeks)

1. D1 discard-changes fix (hours — it's a data-integrity bug)
2. A1 LSP lifecycle for TS/JS → then all configured servers
3. A2 diagnostics → Problems panel live
4. C4 file watcher (stale-buffer data loss)
5. B3 auto-indent on newline
6. C1 command palette
