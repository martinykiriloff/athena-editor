// StatusBarView.swift
// Athena — 22 pt status bar at the bottom of the main window.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

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
                // Git branch — clickable, opens the branch-switcher menu
                // (plan.md item 20 point 1).
                if let branch = gitBranch {
                    StatusBarItem {
                        Menu {
                            Button("Create New Branch…") { promptCreateBranch() }

                            if !localBranches.isEmpty {
                                Divider()
                                ForEach(localBranches) { b in
                                    Button {
                                        Task { await appState.checkoutBranch(b.name) }
                                    } label: {
                                        if b.isCurrent {
                                            Label(b.name, systemImage: "checkmark")
                                        } else {
                                            Text(b.name)
                                        }
                                    }
                                    .disabled(b.isCurrent)
                                }
                            }

                            if !remoteBranches.isEmpty {
                                Divider()
                                Menu("Remote Branches") {
                                    ForEach(remoteBranches) { b in
                                        Button(b.name) {
                                            Task { await appState.checkoutBranch(b.name) }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label(branch, systemImage: "arrow.triangle.branch")
                        }
                        .menuStyle(.borderlessButton)
                    }
                }

                // Update progress / badge
                switch updateService.state {
                case .available(let version, _):
                    StatusBarItem {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Update \(version) found…")
                        }
                        .foregroundStyle(.secondary)
                    }
                case .downloading:
                    StatusBarItem {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            let label = updateService.pendingVersion.map { "Downloading v\($0)…" } ?? "Downloading update…"
                            Text(label)
                        }
                        .foregroundStyle(.secondary)
                    }
                case .readyToInstall:
                    StatusBarItem {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Restarting…")
                        }
                        .foregroundStyle(.secondary)
                    }
                default:
                    EmptyView()
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

                // Cursor position — the FOCUSED group's active tab (plan.md
                // item 22), so this tracks whichever pane the user is in.
                if let tab = appState.focusedTab {
                    Text("Ln \(tab.cursorLine)  Col \(tab.cursorColumn)")
                }

                // Language
                if let tab = appState.focusedTab {
                    Text(tab.language.rawValue.capitalized)
                }
            }
            .padding(.trailing, 12)
        }
        .font(.system(size: appState.sf(11), design: .monospaced))
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

    private var localBranches: [GitBranch] {
        appState.branches.filter { !$0.isRemote }
    }

    private var remoteBranches: [GitBranch] {
        appState.branches.filter { $0.isRemote }
    }

    /// NSAlert-with-accessory-`NSTextField` prompt, matching
    /// `EditorView.Coordinator.promptGoToLine`/`promptRenameSymbol`'s pattern.
    /// Confirming creates the branch off HEAD and checks it out in one step
    /// (`GitService.createBranch` runs `git checkout -b`).
    private func promptCreateBranch() {
        let alert = NSAlert()
        alert.messageText = "Create New Branch"
        alert.informativeText = "Enter a name for the new branch:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { await appState.createAndCheckoutBranch(named: name) }
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
