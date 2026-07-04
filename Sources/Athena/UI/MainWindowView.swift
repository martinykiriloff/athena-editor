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
        layoutContent
            .frame(minWidth: 900, minHeight: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay { if appState.showQuickOpen { QuickOpenView() } }
            // Break the notification chain into two modifiers so the type-checker
            // doesn't time out on CI (each ViewModifier is type-checked independently).
            .modifier(FileNotificationHandlers(appState: appState, newWindow: { openWindow(id: "main") }))
            .modifier(SystemNotificationHandlers(appState: appState, updateService: updateService))
    }

    private var layoutContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ActivityBarView()
                    .frame(width: 48)

                if appState.showSidebar {
                    SidebarView()
                        .frame(width: appState.sidebarWidth)
                    ResizeDivider(axis: .vertical) { delta in
                        appState.sidebarWidth = (dragBaseSidebarWidth + delta).clamped(to: 160...600)
                    }
                    .onAppear { dragBaseSidebarWidth = appState.sidebarWidth }
                    .onChange(of: appState.sidebarWidth) { _, v in dragBaseSidebarWidth = v }
                }

                EditorSplitView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if appState.showClaudePanel {
                    ResizeDivider(axis: .vertical) { delta in
                        appState.claudePanelWidth = (dragBaseClaudeWidth - delta).clamped(to: 240...700)
                    }
                    .onAppear { dragBaseClaudeWidth = appState.claudePanelWidth }
                    .onChange(of: appState.claudePanelWidth) { _, v in dragBaseClaudeWidth = v }

                    ClaudePanel()
                        .frame(width: appState.claudePanelWidth)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBarView()
                .frame(height: 22)
        }
    }
}

// MARK: - Notification handler modifiers
// Split across two structs so neither body grows large enough to time out the
// Swift type-checker on slower CI machines.

private struct FileNotificationHandlers: ViewModifier {
    let appState: AppState
    let newWindow: () -> Void

    func body(content: Content) -> some View {
        content
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
            .onReceive(NotificationCenter.default.publisher(for: .athenaSaveAs)) { _ in
                Task { await appState.saveActiveTabAs() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .athenaRevertFile)) { _ in
                Task { await appState.revertActiveTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .athenaCloseFolder)) { _ in
                Task { await appState.closeFolder() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .athenaNewWindow)) { _ in
                newWindow()
            }
    }
}

private struct SystemNotificationHandlers: ViewModifier {
    let appState: AppState
    let updateService: UpdateService

    func body(content: Content) -> some View {
        content
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
    }
}

// MARK: - Comparable+clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
