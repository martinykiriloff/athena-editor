// DebugConsoleView.swift
// Athena — REPL console for evaluating expressions in the paused debug frame.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - DebugConsoleView

/// Bottom-panel tab (plan.md item 24, "F5") — a scrollback transcript of
/// evaluated expressions plus a text input, evaluated via the same
/// `DebugService.evaluate(...)` call watch expressions use (`context: "repl"`
/// per DAP convention, vs. `"watch"`). The input is disabled while the
/// debugger isn't paused, since `evaluate` needs a live, paused frame.
struct DebugConsoleView: View {
    @Environment(AppState.self) private var appState
    @State private var inputText: String = ""

    private var isPaused: Bool {
        if case .paused = appState.debugState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            inputRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if appState.debugConsoleEntries.isEmpty {
                        Text(isPaused
                             ? "Evaluate expressions in the paused frame…"
                             : "Start debugging and pause execution to evaluate expressions.")
                            .font(.system(size: appState.sf(12)))
                            .foregroundColor(.secondary)
                            .padding(8)
                    } else {
                        ForEach(appState.debugConsoleEntries) { entry in
                            consoleEntryRow(entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .id("bottom")
            }
            .onChange(of: appState.debugConsoleEntries.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func consoleEntryRow(_ entry: DebugConsoleEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("› \(entry.expression)")
                .font(.system(size: appState.sf(12), design: .monospaced))
                .foregroundColor(.secondary)
            Text(entry.result)
                .font(.system(size: appState.sf(12), design: .monospaced))
                .foregroundColor(entry.isError ? .red : .primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Input row

    private var inputRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: appState.sf(11)))
                .foregroundColor(.secondary)
            TextField(isPaused ? "Evaluate expression…" : "Pause execution to evaluate expressions",
                      text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: appState.sf(12), design: .monospaced))
                .disabled(!isPaused)
                .onSubmit {
                    let expression = inputText
                    inputText = ""
                    Task { await appState.evaluateInConsole(expression) }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
