// SidebarView.swift
// Athena — sidebar container that hosts the active panel view.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            SidebarHeaderView(title: panelTitle)

            Divider()

            // ── Panel content ─────────────────────────────────────────────
            Group {
                switch appState.activeSidebarPanel {
                case .files:
                    FileTreeView()
                case .git:
                    GitPanelView()
                case .search:
                    SearchPanelView()
                case .database:
                    DBConnectionsView()
                case .sfcc:
                    SFCCSidebarView()
                case .npm:
                    NPMScriptsView()
                case .debug:
                    DebugSidebarView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .trailing) {
            Divider()
        }
    }

    // MARK: Helpers

    private var panelTitle: String {
        switch appState.activeSidebarPanel {
        case .files:      return "Files"
        case .git:        return "Source Control"
        case .search:     return "Search"
        case .database:   return "DB Connections"
        case .sfcc:       return "SFCC Sandboxes"
        case .npm:        return "NPM Scripts"
        case .debug:      return "Run & Debug"
        }
    }
}

// MARK: - SidebarHeaderView

private struct SidebarHeaderView: View {
    let title: String
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: appState.sf(11), weight: .semibold, design: .default))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                // smallCaps would require a font that supports it; uppercase + tracking
                // gives the same visual result universally.
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 30)
    }
}
