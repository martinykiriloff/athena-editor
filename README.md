# Athena

AI-first code editor built on Electron. Monaco editor core, Claude agent embedded — think VS Code with Claude Code wired directly into the shell.

## What it does

- **Monaco editor** — full VS Code editing experience: syntax highlighting, multi-tab, Darcula theme, Fira Code ligatures
- **Claude AI dock** — chat panel powered by `@anthropic-ai/claude-agent-sdk`; sessions persist, tool calls require user permission before executing
- **Integrated terminal** — real PTY via `node-pty` + xterm.js, ligature support
- **File explorer** — tree view with live file watching (chokidar); clicking imports jumps to definition
- **Git panel** — source control, diff viewer, history graph via `simple-git`
- **Test runner** — Jest integration with a test explorer and results panel
- **Problems panel** — ESLint diagnostics surfaced inline
- **VS Code keymap** — Cmd+P quick open, Cmd+Shift+P command palette, Cmd+B sidebar, Cmd+W close tab, Ctrl+Tab cycling, and more
- **Resizable layout** — activity bar → sidebar → editor area → bottom panel → chat dock, all splittable via allotment

## Stack

| Layer | Tech |
|---|---|
| Shell | Electron 39 |
| UI | React 19 + TypeScript |
| Build | electron-vite + Vite 7 |
| Editor | Monaco Editor 0.55 |
| AI | `@anthropic-ai/claude-agent-sdk` |
| Terminal | node-pty + xterm.js |
| Git | simple-git |
| State | Zustand |

## Keyboard shortcuts (VS Code map)

| Shortcut | Action |
|---|---|
| `Cmd+P` | Quick Open — fuzzy file picker |
| `Cmd+Shift+P` | Command Palette |
| `Cmd+B` | Toggle sidebar |
| `Cmd+J` / `Cmd+\`` | Toggle bottom panel |
| `Cmd+S` | Save active file |
| `Cmd+Shift+S` | Save all |
| `Cmd+W` | Close active tab |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous tab |
| `Cmd+Shift+]` / `Cmd+Shift+[` | Next / previous tab (Mac style) |
| `Cmd+1–9` | Jump to tab by index |
| `Cmd+Shift+E` | Show Explorer |
| `Cmd+Shift+G` | Show Source Control |
| `Cmd+Shift+T` | Show Tests |

## Setup

```bash
npm install
```

## Development

```bash
npm run dev
```

## Build

```bash
# macOS
npm run build:mac

# Windows
npm run build:win

# Linux
npm run build:linux
```

## Lint / typecheck

```bash
npm run lint
npm run typecheck
```

## Architecture

```
src/
  main/           # Electron main process
    services/     # claudeService, gitService, ptyService, fileService, eslintService, jestService
    ipc.ts        # IPC handlers bridging main ↔ renderer
  preload/        # Context bridge (window.api)
  renderer/
    components/   # editor, chat, git, explorer, panel, layout
    store/        # Zustand slices (editor, workspace, chat, git, jest, layout, problems)
```

Claude runs in the main process via the agent SDK; events stream to the renderer over `claude:event` IPC. Tool permission prompts surface to the user before any tool executes.
