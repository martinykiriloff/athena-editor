---
name: macos-web-ide
description: Product + architecture lens for building Athena into the optimal native macOS IDE for fullstack web development. Use when scoping, prioritizing, or designing IDE features (LSP, debugger, terminal, git, search, language support, AI assist). Trigger when the user asks what to build next, how a web-dev feature should work, or to design an editor capability end to end.
---

# macOS Web-Dev IDE — product & architecture lens

Frame every feature around one user: a **fullstack web developer on macOS** (TypeScript/JavaScript, React/Next.js, Node, Python, Go/Rust services, SQL databases, plus SFCC/Demandware). The goal is a **fast, native, single-window IDE** that beats Electron editors on responsiveness and OS integration while matching the workflows web devs expect from VS Code.

## North-star principles

1. **Native speed is the moat.** Every feature must feel instant. Native AppKit/SwiftUI, no web view shells. If a feature can't be made fast, redesign it.
2. **VS Code parity where it builds muscle memory.** Keybindings, Cmd+P quick-open, command palette behavior, panel layout, terminal feel. Don't make users relearn motions; differentiate on speed and integration, not novelty.
3. **The web-dev inner loop is sacred.** Edit → save → see result. Optimize: fast LSP, format-on-save, hot terminal, npm/script runner one keystroke away, debugger that attaches to Node/Chrome/Next.js cleanly.
4. **Meet projects where they are.** Read `package.json`, `tsconfig`, `.vscode/launch.json`, `.nvmrc`, monorepo workspaces. Infer, don't make users configure.
5. **AI as an accelerator, not a takeover.** Claude assist is streaming, scoped to context, and stays out of the way until invoked.

## What "optimal for web dev" concretely means

| Pillar | Bar to hit |
|---|---|
| Language intelligence | LSP for TS/JS/Python/Go/Rust/Swift: completion, diagnostics, hover, go-to-def, rename, format-on-save |
| Debugging | DAP-based: Node, Chrome/CDP, Next.js, Python (lldb for native). Breakpoints, step, variables, call stack |
| Terminal | Real shell (SwiftTerm), multiple instances, runs in workspace cwd, inherits env |
| Tasks | npm/pnpm/yarn script runner surfaced in UI; one-click run with live output |
| Git | Status, stage, commit, blame-per-line, diff — without leaving the window |
| Search | Ripgrep workspace search, regex + case, fast on large monorepos |
| Navigation | Cmd+P fuzzy open, Cmd+Click import resolution, go-to-line, symbol nav |
| Web languages | First-class TS/JS/JSX/TSX, CSS/SCSS, HTML, JSON, plus ISML/DS for SFCC |
| AI | Claude streaming, dual-account, file/selection context |

## How to scope a new feature (use this order)

1. **Who hits this in the inner loop, how often?** High-frequency pains (slow completion, clunky debug attach, manual script running) beat rare nice-to-haves.
2. **Is there a VS Code mental model?** Match it unless we can clearly do better. Name commands and keybindings to match.
3. **What does it read from the project?** Lean on existing config files before inventing UI/settings.
4. **Where does it live in the architecture?** New capability → an `actor` service + state on `AppState` + a thin SwiftUI panel. Protocol-based integrations (LSP=JSON-RPC, DAP, CDP) follow the existing client patterns.
5. **How does it stay fast?** Async on an actor, incremental updates, no main-thread blocking, cancellable.
6. **What's the smallest shippable slice?** Cut to a vertical slice that works end-to-end, then iterate.

## Reality checks before recommending

- Does it block the main thread? Then redesign — heavy work is `async` on a service actor.
- Does it duplicate an existing service (Git, Search, LSP, Debug, NPMScript)? Extend, don't fork.
- Does it require a new dependency? Justify vs. platform SDK; keep the dep list short (currently just GRDB + SwiftTerm).
- Will it work on a real monorepo, not just a toy repo? Validate against scale.

## Output style

When asked "what next?" give a **ranked, justified shortlist** tied to inner-loop impact — not an exhaustive menu. When designing a feature, produce: user story → VS Code analog → data it reads → service/state/UI breakdown → smallest shippable slice → fast-path notes. Recommend, don't survey.
