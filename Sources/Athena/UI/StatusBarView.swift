// StatusBarView.swift
// Athena — 22 pt status bar at the bottom of the main window.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - StatusBarView

struct StatusBarView: View {
    @Environment(AppState.self)      private var appState
    @Environment(UpdateService.self) private var updateService

    // MARK: Diagnostic counts

    private var errorCount: Int {
        appState.diagnostics.values.reduce(0) { count, diags in
            count + diags.filter { $0.severity == .error }.count
        }
    }

    private var warningCount: Int {
        appState.diagnostics.values.reduce(0) { count, diags in
            count + diags.filter { $0.severity == .warning }.count
        }
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            // ── Left cluster ──────────────────────────────────────────────
            HStack(spacing: 8) {
                // Git branch
                if let branch = gitBranch {
                    StatusBarItem {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                }

                // Update available badge
                if updateService.updateAvailable {
                    StatusBarItem {
                        Button {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        } label: {
                            Label("Update available", systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(Color.blue)
                        }
                        .buttonStyle(.plain)
                        .help("A new version of Athena is available — click to open Settings")
                    }
                }

                // Error count
                StatusBarItem {
                    Label("\(errorCount)", systemImage: "xmark.circle")
                        .foregroundStyle(errorCount > 0 ? Color.red : Color.secondary)
                }

                // Warning count
                StatusBarItem {
                    Label("\(warningCount)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(warningCount > 0 ? Color.yellow : Color.secondary)
                }
            }
            .padding(.leading, 8)

            Spacer()

            // ── Right cluster ─────────────────────────────────────────────
            HStack(spacing: 12) {
                // Generic status message
                if !appState.statusMessage.isEmpty {
                    Text(appState.statusMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Cursor position
                if let tab = appState.activeTab {
                    Text("Ln \(tab.cursorLine)  Col \(tab.cursorColumn)")
                }

                // Language
                if let tab = appState.activeTab {
                    Text(tab.language.rawValue.capitalized)
                }
            }
            .padding(.trailing, 12)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: Helpers

    private var gitBranch: String? {
        guard appState.workspace != nil else { return nil }
        let branch = appState.gitStatus.branch
        return branch.isEmpty ? nil : branch
    }
}

// MARK: - StatusBarItem

/// A simple container that provides consistent padding and style for status bar segments.
private struct StatusBarItem<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .fixedSize()
    }
}
