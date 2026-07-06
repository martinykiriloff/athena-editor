// TabBarView.swift
// Athena — horizontal scrollable tab bar above the editor.
// Swift 6, strict concurrency.

import AppKit
import SwiftUI

// MARK: - TabBarView

struct TabBarView: View {
    /// Which editor group this bar controls (plan.md item 22) — defaults to
    /// `.primary` so every pre-existing call site (single-pane) is
    /// unaffected; the secondary pane's own `EditorPaneView` instantiates a
    /// second `TabBarView(side: .secondary)`.
    var side: EditorGroupSide = .primary
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable tab list
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(appState.tabs(in: side)) { tab in
                        TabItemView(tab: tab, side: side)
                        Divider()
                            .frame(height: 16)
                    }
                }
            }

            Divider()
                .frame(height: 16)

            // Add-tab button
            Button {
                appState.openNewTab(in: side)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: appState.sf(12), weight: .medium))
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
    let side: EditorGroupSide

    @Environment(AppState.self) private var appState
    @State private var isHovering: Bool = false

    private var isActive: Bool {
        appState.activeTabId(in: side) == tab.id
    }

    var body: some View {
        HStack(spacing: 6) {
            // Language icon
            languageIcon
                .font(.system(size: appState.sf(12)))
                .frame(width: 14)

            // Title
            Text(tab.title)
                .font(.system(size: appState.sf(12)))
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
                            .font(.system(size: appState.sf(10), weight: .medium))
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
        .onTapGesture { appState.activateTab(tab.id) }
        .overlay { MiddleClickDetector { appState.closeTab(tab.id) } }
        .contextMenu {
            Button("Close") { appState.closeTab(tab.id) }
            Button("Close Others") {
                for t in appState.tabs(in: side) where t.id != tab.id {
                    appState.closeTab(t.id)
                }
            }
            Button("Close All") {
                let ids = appState.tabs(in: side).map { $0.id }
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
        case .isml:      return "curlybraces.square.fill"
        case .ds:        return "doc.text.fill"
        case .image:     return "photo.fill"
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
        case .isml:       return Color(red: 0.0, green: 0.68, blue: 0.94)   // SFCC teal
        case .ds:         return Color(red: 0.0, green: 0.68, blue: 0.94)
        case .markdown:   return .white
        case .image:      return .pink
        case .plaintext:  return .secondary
        }
    }
}

// MARK: - Middle-click support

// Transparent overlay that intercepts button-2 (scroll-wheel click) events and
// closes the tab. hitTest returns nil for every other event so left-click,
// hover, and context-menu handling fall through to the SwiftUI content below.
private struct MiddleClickDetector: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickNSView {
        MiddleClickNSView(action: action)
    }

    func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
        nsView.action = action
    }
}

final class MiddleClickNSView: NSView {
    var action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Accept hit only for middle-click; everything else falls through to SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent,
           event.type == .otherMouseDown,
           event.buttonNumber == 2,
           bounds.contains(point) {
            return self
        }
        return nil
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        action()
    }
}
