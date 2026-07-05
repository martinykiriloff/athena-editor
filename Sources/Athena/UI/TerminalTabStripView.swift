// TerminalTabStripView.swift
// Athena — compact tab strip for the integrated terminal panel's sessions.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - TerminalTabStripView

/// A smaller, simpler sibling of `TabBarView` for the terminal panel's
/// sessions (plan.md item 21). Mirrors its close-button/"+"-button visual
/// language, but drops dirty-state tracking (terminal sessions have no
/// "unsaved" concept) and drag-reorder (out of scope for this pass).
struct TerminalTabStripView: View {
    @Environment(AppState.self) private var appState

    private let stripHeight: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(appState.terminalSessions) { session in
                        TerminalTabItemView(session: session)
                        Divider()
                            .frame(height: 14)
                    }
                }
            }

            Divider()
                .frame(height: 14)

            Button {
                appState.newTerminalSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: appState.sf(11), weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: stripHeight)
            }
            .buttonStyle(.plain)
            .help("New Terminal")

            Spacer(minLength: 0)
        }
        .frame(height: stripHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - TerminalTabItemView

private struct TerminalTabItemView: View {
    let session: TerminalSession

    @Environment(AppState.self) private var appState
    @State private var isHovering: Bool = false

    private var isActive: Bool {
        appState.activeTerminalSessionId == session.id
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: appState.sf(11)))
                .foregroundColor(isActive ? .primary : .secondary)

            Text(session.title)
                .font(.system(size: appState.sf(12)))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)

            // Close button — shown on hover or for the active session.
            if isHovering || isActive {
                Button {
                    appState.closeTerminalSession(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: appState.sf(9), weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 90, maxWidth: 160, alignment: .leading)
        .frame(height: 28)
        .background(tabBackground)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { appState.activateTerminalSession(session.id) }
        .contextMenu {
            Button("Close") { appState.closeTerminalSession(session.id) }
        }
    }

    @ViewBuilder
    private var tabBackground: some View {
        if isActive {
            Color(nsColor: .selectedControlColor)
        } else if isHovering {
            Color.primary.opacity(0.05)
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }
}
