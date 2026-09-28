# Tasks — usability

Gaps found in a usability pass (2026-09-25). Each was confirmed by reading the
code. Work top to bottom; groups 1–2 (except quick fixes) are the next batch.

## 1. Looks like it works, doesn't

- [x] **Problems panel rows navigate to the diagnostic.** Clicking a row opens
      the file and moves the caret to its line/column. Today rows are
      display-only. `UI/BottomPanelView.swift` (`ProblemsView`, `DiagnosticRowView`).
- [x] **Terminal line-editing keys.** ⌘⌫ (delete to line start, send `^U`),
      ⌘← / ⌘→ (line start/end, send `^A` / `^E`), ⌥← / ⌥→ (word jump). The log
      currently shows `Unhandle selector deleteToBeginningOfLine:` from SwiftTerm.
      `UI/TerminalView.swift`.

## 2. VS Code muscle memory

- [x] **Reopen closed tab (⇧⌘T).** Keep a stack of closed tabs (URL + cursor
      position), restore the most recent. New `KeyAction` with a VS Code id.
- [x] **Preview tabs.** A single click in the explorer opens a preview tab
      (italic title) that the next single click replaces. Editing, saving or
      double-clicking makes it permanent.
- [x] **Next/previous problem (F8 / ⇧F8).** Cycles through diagnostics across
      files, opening each at its position.
- [x] **Quick fixes (⌘.).** Request LSP `textDocument/codeAction` at the caret
      or diagnostic, show a lightbulb/menu, and apply the returned
      `WorkspaceEdit`. The largest item here — do it on its own. Note: ⌘. is
      currently bound to `claudeInterrupt`, so pick one binding. → ⌘. is Quick
      Fix; Stop Claude is unbound (Esc and the Stop button still work).

## 3. Finding your way

- [ ] **Recent folders on the Welcome screen.** List recently opened
      workspaces (click to open, remove from list). `UI/WelcomeView.swift`.
- [ ] **Search in Settings.** A filter field that narrows the settings form to
      matching labels. `UI/SettingsView.swift`.
- [ ] **First-run checks.** Detect a missing `claude` CLI, `git` or language
      server and say so plainly (with an install hint) instead of a panel
      failing quietly.

## 4. Polish

- [ ] **Remove the legacy Claude chat.** The bottom-panel tab is hidden; delete
      `UI/ChatView.swift`, `BottomPanel.chat` and the `chatMessages` state, and
      check whether `ClaudeService` still has other callers (`LSPManager`).
- [ ] **Per-tab actions in the bottom panel header.** Move Output's Clear
      button into the header (like the terminal's + / Kill), and give Debug
      Console a Clear too, then drop Output's separate toolbar row.

## Done

- [x] Claude panel: titled header, account switcher only when a second
      account exists, composer card with pickers beside the input, markdown
      blocks in replies, starter prompts, Esc stops a turn.
- [x] Activity bar tooltips and active indicator; status bar in the system font.
- [x] VS Code-style terminal panel: single header row with actions,
      maximize/restore, terminal list on the right, ⌃⇧` New Terminal.
