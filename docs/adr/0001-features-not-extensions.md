# 0001 — Capabilities ship as native Features, never as VS Code extensions

Date: 2026-09-04
Status: accepted

## Context

Athena's target is VS Code parity for a fullstack-web workflow, and the
capabilities users name are VS Code extensions: GitLens, a database client,
the Prophet SFCC debugger. Two ways to deliver them:

1. Embed a Node.js extension host and enough of the `vscode` API surface to
   run the real extensions unmodified.
2. Reimplement each capability natively in Swift as a built-in Feature.

Option 1 would give instant access to the whole marketplace, but the `vscode`
API is thousands of entry points, its extension host is Node, and every
extension's UI assumes VS Code's webviews and tree views. Athena is a native
AppKit/SwiftUI app whose CLAUDE.md forbids Node in its own codebase. The
extension host would become the largest and least native subsystem in the app,
and its fidelity would be judged against VS Code itself.

## Decision

Athena runs no third-party extensions. Every wanted capability is a Feature:
implemented natively, shipped with the app, toggled in Settings. External
tools (git, ripgrep, language servers, debug adapters) may be spawned as
subprocesses, as they already are; extension code never runs in-process.

## Consequences

- Each Feature is a bounded Swift implementation with tests, not a
  compatibility layer.
- Behaviour of a VS Code extension may be reimplemented; its source is not
  copied. GitLens and the Database Client extension are proprietary.
- Users cannot install arbitrary extensions. Requests for a capability become
  Feature requests.
- A future native plugin API is not precluded, but is out of scope until a
  Feature needs it.
