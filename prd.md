# PRD — Athena: closing the gap with VS Code and WebStorm

Status: draft, 2026-11-01. Source: codebase analysis (grep- and read-based; not profiled or run).
Scope rule (CONTEXT.md, ADR 0001): every capability is a native **Feature**, never a plugin. Target is the daily fullstack-web workflow, not all of VS Code.

## Goals
1. Typing stays instant on large files.
2. A VS Code user finds their daily editing, navigation, git and test workflow without a mouse detour.
3. Language tooling works out of the box for the web stack.

## Non-goals
Third-party extension host, remote/SSH development (deferred), non-web language depth.

## Constraints
Swift 6 strict concurrency with zero warnings; services are actors; domain types in `SharedTypes.swift`; no new dependency without justification (tree-sitter is the one justified candidate); `make build-debug && make test` green before done.

---

## P0 — Foundations

### 1. Incremental highlighting
- **Problem:** `applyHighlighting` re-runs every regex over the whole document and calls `setAttributedString` after each keystroke (`EditorView.swift:1626`, `SyntaxHighlighter.swift:60`).
- **Requirement:** re-highlight only the edited paragraph range plus the visible range; apply attributes in place; never replace the text storage; selection and undo unaffected.
- **Acceptance:** typing latency on a 10k-line file does not scale with file size; multi-range selections survive; existing tests pass.

### 2. Large-file mode
- Above a size/line threshold, disable highlighting, minimap, blame and LSP sync; show a dismissible banner. Threshold is a setting.

### 3. Code folding
- Fold gutter arrows, fold/unfold at caret, fold all/unfold all, fold level N, persisted fold state.
- Source: LSP `foldingRange` when available, indentation/brace fallback. Key bindings follow VS Code (⌥⌘[ , ⌥⌘]).
- Depends on 1 (shared attribute pass).

### 4. Language coverage
- Highlighting for: TSX/JSX, YAML, SQL, shell, PHP, Java, Kotlin, C/C++, Ruby, Vue, Svelte, Dockerfile, TOML, GraphQL, `.env`.
- LSP: CSS/HTML/JSON (vscode-langservers-extracted), tailwindcss, yaml, vue, svelte, prisma; server command configurable in Settings; install hint when missing (extends `ToolCheckService`).

## P1 — Daily-driver gaps

### 5. LSP extras
Document highlight, workspace symbol (⌘T), inlay hints, semantic tokens, code lens, call/type hierarchy, `didChangeWatchedFiles`, `willRenameFiles` (update imports on rename/move), linked editing, organize imports, fix-all on save.

### 6. Tasks and launch
`tasks.json` parsing, Run Task palette, problem matchers feeding the Problems panel, compound launch configs.

### 7. Test runner
Jest / Vitest / pytest / XCTest discovery, gutter run/debug, inline pass/fail, re-run failed.

### 8. Editor basics
Auto-close/rename HTML tags, Emmet, trim trailing whitespace and final newline on save, `.editorconfig`, indent guides, sticky scroll, bracket-pair colours, go to matching bracket, column selection, add cursor above/below, sort/transform/join lines.

### 9. Hot exit and session restore
Restore tabs, unsaved buffers, cursor, folds, panel layout and open folder on relaunch.

### 10. Local history
Per-file snapshots on save independent of git; timeline view; diff and restore.

### 11. Git depth
Merge/rebase flows, 3-way merge editor, hunk-level stage/revert in gutter, branch graph, cherry-pick, amend, tags, file/line history, PR view and CI status.

## P2 — WebStorm-class intelligence

12. Refactor menu (extract, move, change signature, safe delete) built on LSP code actions; search-everywhere palette.
13. Framework awareness: React/Next routes and props, NestJS, Tailwind class completion and colour preview, `tsconfig` path aliases, monorepo graph, package.json version hovers.
14. Debugger: conditional breakpoints, logpoints, data/exception breakpoints, watch expressions, inline values, hover.
15. HTTP client (`.http` files) and SQL console with schema-aware completion.
16. Diagnostics: ESLint/Biome/`tsc` integration, fix-on-save, unused-import inspection, `npm audit`.

## P3 — Platform and polish

17. Remote development (SSH, dev containers) — deferred.
18. Settings sync, profiles, workspace trust prompt before running tasks from untrusted folders.
19. Accessibility: VoiceOver, high contrast, reduced motion.
20. Distribution: notarisation, verified auto-update, crash reporting, opt-in telemetry.
21. Internal health: split `AppState` (3.5k lines) and `EditorView` (2.6k) by feature; typing-latency and project-open benchmarks; UI tests for main flows.

## Delivery order
1 → 2 → (tree-sitter decision) → 3 → 4 → 6/7 → 9/10 → 8 → 11 → 5 → rest.

## Wave 1 (this session)
Independent, low-conflict items, each built in an isolated worktree and merged one at a time after build + test:
- A: items 1 + 2 (highlighting, large-file mode)
- B: item 8 subset — trim whitespace / final newline on save, `.editorconfig`
- C: item 9 (hot exit / session restore)
- D: item 10 (local history)
- E: item 6 (`tasks.json` runner)
- F: item 5 subset — document highlight, workspace symbol

Deferred to later waves: 3, 4, 7, 11–21 (depend on A or need design decisions such as tree-sitter).
