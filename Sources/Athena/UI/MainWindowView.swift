// MainWindowView.swift
// Athena — root IDE layout view.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

// MARK: - ResizeDivider

/// A thin drag handle that resizes a dimension in AppState.
struct ResizeDivider: View {
    enum Axis { case vertical, horizontal }

    /// Thickness of the handle, in screen points (not zoomed).
    static let thickness: CGFloat = 4

    let axis: Axis
    /// The size being resized, read once when a drag begins.
    let size: () -> CGFloat
    /// Receives the size captured at drag start and the cumulative drag
    /// translation in screen points; should write the new size to AppState.
    let onDrag: (_ base: CGFloat, _ translation: CGFloat) -> Void

    @State private var isHovering = false
    /// Size at drag start. `DragGesture` translation is cumulative, so it
    /// must be applied to a base that stays fixed for the whole drag.
    @State private var dragBase: CGFloat?

    var body: some View {
        Group {
            switch axis {
            case .vertical:
                Rectangle()
                    .fill(isHovering ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
                    .frame(width: Self.thickness)
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(dragGesture { $0.width })
            case .horizontal:
                Rectangle()
                    .fill(isHovering ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
                    .frame(height: Self.thickness)
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(dragGesture { $0.height })
            }
        }
    }

    private func dragGesture(_ component: @escaping (CGSize) -> CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let base = dragBase ?? size()
                dragBase = base
                onDrag(base, component(value.translation))
            }
            .onEnded { _ in dragBase = nil }
    }
}

// MARK: - EditorSplitView

/// Vertical stack: editor area on top, optional resizable bottom panel below.
private struct EditorSplitView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geo in
            content(height: geo.size.height)
        }
    }

    private func content(height: CGFloat) -> some View {
        let showPanel = appState.showBottomPanel && !appState.isZenMode
        // The panel may take the whole column (unzoomed points); the stored
        // height is only capped at render time so it comes back when the
        // window grows again.
        let maxPanel = max(0, (height - ResizeDivider.thickness) / appState.uiScale)
        let panelHeight = min(appState.bottomPanelHeight, maxPanel)
        // Maximized, the panel takes the column and the editor is hidden —
        // but stays mounted so its scroll/undo state survives the restore.
        let maximized = showPanel && appState.isBottomPanelMaximized

        return VStack(spacing: 0) {
            // Zen mode (plan.md item 28, "C8") centers the editor content
            // with a max width — VS Code-style — rather than letting it
            // stretch full-bleed once the sidebar/activity bar/panel chrome
            // that used to bound it is hidden.
            Group {
                if appState.isZenMode {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        EditorContainerView()
                            .frame(maxWidth: appState.sf(1000))
                        Spacer(minLength: 0)
                    }
                } else {
                    EditorContainerView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: maximized ? 0 : .infinity)
            .opacity(maximized ? 0 : 1)
            .allowsHitTesting(!maximized)
            .clipped()

            if showPanel {
                // Dragging upward (negative translation) grows the panel.
                // Drag deltas are in screen points; the stored height is in
                // unzoomed points so it survives a zoom change unchanged.
                if !maximized {
                    ResizeDivider(axis: .horizontal, size: { panelHeight }) { base, t in
                        appState.bottomPanelHeight = (base - t / appState.uiScale).clamped(to: 0...maxPanel)
                    }
                }

                // One view in both states, so maximizing never remounts the
                // terminals.
                BottomPanelView()
                    .frame(height: maximized ? height : appState.sf(panelHeight))
                    .clipped()
            }
        }
    }
}

// MARK: - MainWindowView

struct MainWindowView: View {
    @Environment(AppState.self)      private var appState
    @Environment(UpdateService.self) private var updateService
    @Environment(\.openWindow)       private var openWindow

    var body: some View {
        layoutContent
            .frame(minWidth: 900, minHeight: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay { if appState.showQuickOpen { QuickOpenView() } }
            .overlay { if appState.showDiffViewer { DiffViewerView() } }
            // Break the notification chain into two modifiers so the type-checker
            // doesn't time out on CI (each ViewModifier is type-checked independently).
            .modifier(FileNotificationHandlers(appState: appState, newWindow: { openWindow(id: "main") }))
            .modifier(SystemNotificationHandlers(appState: appState, updateService: updateService))
            .sheet(isPresented: Binding(
                get: { updateService.isPromptPresented },
                // Closing the sheet any other way counts as "later".
                set: { if !$0 { updateService.remindLater() } }
            )) {
                UpdatePromptView()
            }
    }

    private var layoutContent: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                panelRow(width: geo.size.width)
            }

            if !appState.isZenMode {
                StatusBarView()
                    .frame(height: appState.sf(22))
            }
        }
    }

    /// Activity bar, sidebar, editor and Claude panel. Side panel limits
    /// come from the window's current width, not fixed numbers: each panel
    /// may grow until it meets the other one (squeezing the editor to
    /// nothing) and shrink to zero.
    private func panelRow(width: CGFloat) -> some View {
        let showSidebar = appState.showSidebar && !appState.isZenMode
        let showClaude  = appState.showClaudePanel
        let activityBar = appState.isZenMode ? 0 : appState.sf(48)
        let dividers    = ResizeDivider.thickness * CGFloat((showSidebar ? 1 : 0) + (showClaude ? 1 : 0))
        // Width the two side panels share, in unzoomed points.
        let free = max(0, (width - activityBar - dividers) / appState.uiScale)
        // Stored widths are capped only at render time, so a panel regains
        // its size when the window grows again.
        let sidebarWidth = showSidebar ? min(appState.sidebarWidth, free) : 0
        let claudeWidth  = showClaude ? min(appState.claudePanelWidth, free - sidebarWidth) : 0

        return HStack(spacing: 0) {
            if !appState.isZenMode {
                ActivityBarView()
                    .frame(width: appState.sf(48))
            }

            if showSidebar {
                SidebarView()
                    .frame(width: appState.sf(sidebarWidth))
                    .clipped()
                ResizeDivider(axis: .vertical, size: { sidebarWidth }) { base, t in
                    appState.sidebarWidth = (base + t / appState.uiScale).clamped(to: 0...(free - claudeWidth))
                }
            }

            EditorSplitView()
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            if showClaude {
                ResizeDivider(axis: .vertical, size: { claudeWidth }) { base, t in
                    appState.claudePanelWidth = (base - t / appState.uiScale).clamped(to: 0...(free - sidebarWidth))
                }

                ClaudePanel()
                    .frame(width: appState.sf(claudeWidth))
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
