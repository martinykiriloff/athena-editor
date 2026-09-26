// TerminalListView.swift
// Athena — VS Code-style terminal list shown to the right of the terminal.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - TerminalListView

/// One row per terminal session. Click to switch, hover for Kill, and the
/// context menu to rename. New/Kill for the active
/// session also live in the bottom panel header.
struct TerminalListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(appState.terminalSessions) { session in
                    TerminalListRow(session: session)
                }
            }
            .padding(.vertical, appState.sf(4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - TerminalListRow

private struct TerminalListRow: View {
    let session: TerminalSession

    @Environment(AppState.self) private var appState
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    private var isActive: Bool {
        appState.activeTerminalSessionId == session.id
    }

    var body: some View {
        HStack(spacing: appState.sf(6)) {
            Image(systemName: "apple.terminal")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: appState.sf(14))

            if isRenaming {
                TextField("Terminal name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: appState.sf(12)))
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onKeyPress(.escape) {
                        isRenaming = false
                        return .handled
                    }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(session.title)
                    .font(.system(size: appState.sf(12)))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if isHovering && !isRenaming {
                Button {
                    appState.closeTerminalSession(session.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: appState.sf(10.5)))
                        .foregroundStyle(.secondary)
                        .frame(width: appState.sf(18), height: appState.sf(18))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Kill Terminal")
            }
        }
        .padding(.horizontal, appState.sf(8))
        .frame(height: appState.sf(24))
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: appState.sf(2))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { appState.activateTerminalSession(session.id) }
        .contextMenu {
            Button("Rename…") { beginRename() }
            Divider()
            Button("Kill Terminal") { appState.closeTerminalSession(session.id) }
        }
        .help(session.currentDirectory ?? session.title)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            Color.primary.opacity(0.1)
        } else if isHovering {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }

    // MARK: - Rename

    private func beginRename() {
        appState.activateTerminalSession(session.id)
        draftTitle = session.title
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        appState.renameTerminalSession(session.id, to: draftTitle)
    }
}
