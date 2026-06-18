// TabBarView.swift
// Athena — horizontal scrollable tab bar above the editor.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - TabBarView

struct TabBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable tab list
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(appState.openTabs) { tab in
                        TabItemView(tab: tab)
                        Divider()
                            .frame(height: 16)
                    }
                }
            }

            Divider()
                .frame(height: 16)

            // Add-tab button
            Button {
                let newTab = TabModel.untitled()
                appState.openTabs.append(newTab)
                appState.activeTabId = newTab.id
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: tabBarHeight)
            }
            .buttonStyle(.plain)
            .help("New Tab")
        }
        .frame(height: tabBarHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private let tabBarHeight: CGFloat = 36
}

// MARK: - TabItemView

private struct TabItemView: View {
    let tab: TabModel

    @Environment(AppState.self) private var appState
    @State private var isHovering: Bool = false

    private var isActive: Bool {
        appState.activeTabId == tab.id
    }

    var body: some View {
        HStack(spacing: 6) {
            // Language icon
            languageIcon
                .font(.system(size: 12))
                .frame(width: 14)

            // Title
            Text(tab.title)
                .font(.system(size: 12))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)

            // Dirty indicator / close button
            ZStack {
                // Dirty dot — shown when not hovering and tab is dirty
                if tab.isDirty && !isHovering {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                }

                // Close button — shown on hover or for active tab
                if isHovering || isActive {
                    Button {
                        appState.closeTab(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 14, height: 14)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 100, maxWidth: 200, alignment: .leading)
        .frame(height: 36)
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
        .onTapGesture { appState.activeTabId = tab.id }
        // Middle-click to close
        .simultaneousGesture(
            TapGesture(count: 1)
                .modifiers(.init())
        )
        .contextMenu {
            Button("Close") { appState.closeTab(tab.id) }
            Button("Close Others") {
                for t in appState.openTabs where t.id != tab.id {
                    appState.closeTab(t.id)
                }
            }
            Button("Close All") {
                let ids = appState.openTabs.map { $0.id }
                for id in ids { appState.closeTab(id) }
            }
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

    @ViewBuilder
    private var languageIcon: some View {
        let lang = tab.fileURL.map { Language.detect(from: $0) } ?? .plaintext
        Image(systemName: languageIconName(for: lang))
            .foregroundColor(languageIconColor(for: lang))
    }

    private func languageIconName(for language: Language) -> String {
        switch language {
        case .markdown:  return "doc.richtext.fill"
        case .plaintext: return "doc.text"
        default:         return "doc.text.fill"
        }
    }

    private func languageIconColor(for language: Language) -> Color {
        switch language {
        case .swift:      return .orange
        case .typescript: return .blue
        case .javascript: return .yellow
        case .python:     return .green
        case .rust:       return Color(red: 0.9, green: 0.4, blue: 0.2)
        case .go:         return .cyan
        case .json:       return .gray
        case .css:        return .purple
        case .html:       return .orange
        case .markdown:   return .white
        case .plaintext:  return .secondary
        }
    }
}
