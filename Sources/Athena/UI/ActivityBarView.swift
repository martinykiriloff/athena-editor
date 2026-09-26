// ActivityBarView.swift
// Athena — leftmost vertical icon strip (activity bar).
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - ActivityBarView

struct ActivityBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    // Ordered list of (panel, SF symbol name, tooltip) triples.
    private let panels: [(SidebarPanel, String, String)] = [
        (.files,    "folder.fill",             "Explorer (⇧⌘E)"),
        (.git,      "arrow.triangle.branch",   "Source Control (⇧⌘G)"),
        (.search,   "magnifyingglass",         "Search (⇧⌘F)"),
        (.database, "cylinder.split.1x2.fill", "Databases"),
        (.outline,  "list.bullet.indent",      "Outline"),
        (.sfcc,     "cloud.fill",              "SFCC Sandboxes"),
        (.npm,      "shippingbox.fill",        "NPM Scripts"),
        (.debug,    "ladybug.fill",            "Run and Debug"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Top: left-sidebar panel icons ─────────────────────────────
            ForEach(panels, id: \.0) { panel, symbol, help in
                ActivityBarButton(
                    systemImage: symbol,
                    help: help,
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
                help: "Claude (⇧⌘A)",
                isActive: appState.showClaudePanel
            ) {
                appState.showClaudePanel.toggle()
            }

            // ── Bottom: settings gear ─────────────────────────────────────
            ActivityBarButton(
                systemImage: "gearshape.fill",
                help: "Settings (⌘,)",
                isActive: false
            ) {
                openSettings()
            }
        }
        .padding(.vertical, appState.sf(4))
        .frame(width: appState.sf(48))
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .trailing) {
            Divider()
        }
    }
}

// MARK: - ActivityBarButton

private struct ActivityBarButton: View {
    let systemImage: String
    let help: String
    let isActive: Bool
    let action: () -> Void
    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: appState.sf(18)))
                .foregroundStyle(isActive ? Color.primary : Color.secondary.opacity(isHovered ? 1 : 0.75))
                .frame(width: appState.sf(48), height: appState.sf(44))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VS Code-style edge marker: the active view is findable at a glance
        // without relying on icon tint alone.
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: appState.sf(2), height: appState.sf(24))
            }
        }
        .onHover { isHovered = $0 }
        .help(help)
    }
}
