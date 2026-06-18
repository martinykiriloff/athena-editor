// ActivityBarView.swift
// Athena — leftmost vertical icon strip (activity bar).
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - ActivityBarView

struct ActivityBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    // Ordered list of (panel, SF symbol name) pairs.
    private let panels: [(SidebarPanel, String)] = [
        (.files,    "folder.fill"),
        (.git,      "arrow.triangle.branch"),
        (.search,   "magnifyingglass"),
        (.database, "cylinder.split.1x2.fill"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Top: left-sidebar panel icons ─────────────────────────────
            ForEach(panels, id: \.0) { panel, symbol in
                ActivityBarButton(
                    systemImage: symbol,
                    isActive: appState.activeSidebarPanel == panel && appState.showSidebar
                ) {
                    if appState.activeSidebarPanel == panel {
                        appState.showSidebar.toggle()
                    } else {
                        appState.activeSidebarPanel = panel
                        appState.showSidebar = true
                    }
                }
            }

            Spacer()

            // ── Bottom: Claude (right panel) ──────────────────────────────
            ActivityBarButton(
                systemImage: "sparkles",
                isActive: appState.showClaudePanel
            ) {
                appState.showClaudePanel.toggle()
            }

            // ── Bottom: settings gear ─────────────────────────────────────
            ActivityBarButton(
                systemImage: "gearshape.fill",
                isActive: false
            ) {
                openSettings()
            }
        }
        .padding(.vertical, 4)
        .frame(width: 48)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .trailing) {
            Divider()
        }
    }
}

// MARK: - ActivityBarButton

private struct ActivityBarButton: View {
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
