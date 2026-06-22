// DebugToolbarView.swift
// Athena — floating debug control bar that overlays the editor when a session is active.
// Swift 6, strict concurrency.

import SwiftUI

struct DebugToolbarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 2) {
            // Continue / Pause
            if case .paused = appState.debugState {
                debugButton(icon: "play.fill",       tint: .green,    help: "Continue (F5)")  { Task { await appState.debugContinue()  } }
            } else {
                debugButton(icon: "pause.fill",      tint: .yellow,   help: "Pause")           { Task { await appState.debugPause()     } }
            }
            debugButton(icon: "arrow.forward",       tint: .primary,  help: "Step Over (F10)") { Task { await appState.debugStepOver()  } }
            debugButton(icon: "arrow.turn.down.right", tint: .primary, help: "Step Into (F11)") { Task { await appState.debugStepIn()  } }
            debugButton(icon: "arrow.turn.up.left",  tint: .primary,  help: "Step Out (⇧F11)") { Task { await appState.debugStepOut()  } }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            // Current location
            if let file = appState.debugCurrentFile, let line = appState.debugCurrentLine {
                Text("\(file.lastPathComponent):\(line)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text(debugStateText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            debugButton(icon: "stop.fill", tint: .red, help: "Stop Debugging") { Task { await appState.stopDebugging() } }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var debugStateText: String {
        switch appState.debugState {
        case .launching: return "Launching…"
        case .running:   return "Running"
        case .paused(let r): return "Paused — \(r)"
        default: return ""
        }
    }

    private func debugButton(icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(tint == .primary ? Color.primary : tint)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
