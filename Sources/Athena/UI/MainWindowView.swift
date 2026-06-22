// MainWindowView.swift
// Athena — root IDE layout view.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

// MARK: - ResizeDivider

/// A thin drag handle that resizes a dimension in AppState.
struct ResizeDivider: View {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    /// Closure receives the raw drag translation delta and should update AppState.
    let onDrag: (CGFloat) -> Void

    @State private var isHovering = false

    var body: some View {
        Group {
            switch axis {
            case .vertical:
                Rectangle()
                    .fill(isHovering ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
                    .frame(width: 4)
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                onDrag(value.translation.width)
                            }
                    )
            case .horizontal:
                Rectangle()
                    .fill(isHovering ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
                    .frame(height: 4)
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                onDrag(value.translation.height)
                            }
                    )
            }
        }
    }
}

// MARK: - EditorSplitView

/// Vertical stack: editor area on top, optional resizable bottom panel below.
private struct EditorSplitView: View {
    @Environment(AppState.self) private var appState

    // Accumulated width before the current drag begins.
    @State private var dragBaseHeight: CGFloat = 0

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            EditorContainerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if appState.showBottomPanel {
                ResizeDivider(axis: .horizontal) { delta in
                    // Dragging upward (negative delta) should increase panel height.
                    let newHeight = (dragBaseHeight - delta)
                        .clamped(to: 100...600)
                    appState.bottomPanelHeight = newHeight
                }
                .onAppear { dragBaseHeight = appState.bottomPanelHeight }
                .onChange(of: appState.bottomPanelHeight) { _, newValue in
                    dragBaseHeight = newValue
                }

                BottomPanelView()
                    .frame(height: appState.bottomPanelHeight)
            }
        }
    }
}

// MARK: - MainWindowView

struct MainWindowView: View {
    @Environment(AppState.self)      private var appState
    @Environment(UpdateService.self) private var updateService
    @Environment(\.openWindow)       private var openWindow

    @State private var dragBaseSidebarWidth: CGFloat = 0
    @State private var dragBaseClaudeWidth: CGFloat = 0

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            // ── Main row ──────────────────────────────────────────────────
            HStack(spacing: 0) {
                // Activity bar (always visible, 48 pt fixed)
                ActivityBarView()
                    .frame(width: 48)

                // Left sidebar (conditionally shown)
                if appState.showSidebar {
                    SidebarView()
                        .frame(width: appState.sidebarWidth)

                    ResizeDivider(axis: .vertical) { delta in
                        let newWidth = (dragBaseSidebarWidth + delta)
                            .clamped(to: 160...600)
                        appState.sidebarWidth = newWidth
                    }
                    .onAppear { dragBaseSidebarWidth = appState.sidebarWidth }
                    .onChange(of: appState.sidebarWidth) { _, newValue in
                        dragBaseSidebarWidth = newValue
                    }
                }

                // Editor + optional bottom panel
                EditorSplitView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right: Claude panel (conditionally shown)
                if appState.showClaudePanel {
                    ResizeDivider(axis: .vertical) { delta in
                        // Dragging the left edge leftward widens the panel
                        let newWidth = (dragBaseClaudeWidth - delta)
                            .clamped(to: 240...700)
                        appState.claudePanelWidth = newWidth
                    }
                    .onAppear { dragBaseClaudeWidth = appState.claudePanelWidth }
                    .onChange(of: appState.claudePanelWidth) { _, newValue in
                        dragBaseClaudeWidth = newValue
                    }

                    ClaudePanel()
                        .frame(width: appState.claudePanelWidth)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Status bar (22 pt fixed) ───────────────────────────────────
            StatusBarView()
                .frame(height: 22)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if appState.showQuickOpen {
                QuickOpenView()
            }
        }
        // Menu commands can't reach @Environment, so they broadcast their
        // intent. Observe those broadcasts here and run them through the same
        // dispatch the keyboard uses, so clicks and shortcuts behave identically.
        .onReceive(NotificationCenter.default.publisher(for: .athenaPerformAction)) { note in
            guard let action = note.object as? KeyAction else { return }
            Task { await appState.perform(action) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaOpenFile)) { note in
            guard let url = note.object as? URL else { return }
            Task { await appState.openFile(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaOpenWorkspace)) { note in
            guard let url = note.object as? URL else { return }
            Task { await appState.openWorkspace(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaSaveAll)) { _ in
            Task { await appState.saveAllTabs() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaZoomIn)) { _ in
            appState.adjustFontSize(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaZoomOut)) { _ in
            appState.adjustFontSize(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaResetZoom)) { _ in
            appState.resetFontSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaGitRefresh)) { _ in
            Task { await appState.refreshGitStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaCheckForUpdates)) { _ in
            Task { await updateService.checkForUpdates() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaNewWindow)) { _ in
            openWindow(id: "main")
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaSaveAs)) { _ in
            Task { await appState.saveActiveTabAs() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaRevertFile)) { _ in
            Task { await appState.revertActiveTab() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .athenaCloseFolder)) { _ in
            appState.closeFolder()
        }
    }
}

// MARK: - Comparable+clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
