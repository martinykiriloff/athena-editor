# 0002 — SFCC script debugging talks to the Script Debugger API natively

Date: 2026-09-04
Status: accepted

## Context

Salesforce Commerce Cloud server scripts are debugged through the Script
Debugger API (SDAPI), an HTTPS/JSON API on the sandbox. In VS Code the Prophet
extension bridges that API to the Debug Adapter Protocol with a Node debug
adapter. Athena already spawns `@vscode/js-debug` under Node for JavaScript,
so driving Prophet's adapter as a subprocess had precedent.

## Decision

Athena implements an SDAPI client in Swift (`SDAPIClient`) and an SFCC debug
session (`SFCCDebugSession`) that plugs into `DebugService` as a third
backend alongside DAP and Chrome DevTools Protocol. Launch configs accept
Prophet's `"type": "prophet"` and credential keys so existing `launch.json`
files work, and credentials fall back to `dw.json`, then to the active Athena
SFCC connection.

## Consequences

- No Node or npm install is required to debug SFCC. Public users get the
  debugger by opening a project with a `dw.json`.
- SDAPI is small (client, breakpoints, threads, frames, variables, eval) and
  is owned end to end, including the halted-thread polling and the 30-second
  timeout reset that keeps halted threads halted.
- The debugger service is now three backends behind one interface; a fourth
  should trigger extracting a backend protocol.
- Prophet's other parts (ISML language support, cartridge upload, log viewer)
  are separate Features; upload and logs already exist.
