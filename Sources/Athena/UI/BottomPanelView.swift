// BottomPanelView.swift
// Athena — bottom panel: Terminal · Problems · Output.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - BottomPanelView

struct BottomPanelView: View {
    @Environment(AppState.self) private var appState

    private var headerHeight: CGFloat { appState.sf(32) }

    var body: some View {
        VStack(spacing: 0) {
            header
            panelContent
        }
    }

    // MARK: Header

    /// One row, as in VS Code: view tabs on the left, then the active view's
    /// own actions and the panel's maximize/close on the right.
    private var header: some View {
        HStack(spacing: appState.sf(2)) {
            // The legacy API-key chat is superseded by the Claude panel; two
            // "Claude" surfaces with different behaviour only confused users.
            ForEach(BottomPanel.allCases.filter { $0 != .chat }, id: \.self) { panel in
                bottomPanelTab(panel)
            }

            Spacer(minLength: appState.sf(8))

            viewActions

            Divider()
                .frame(height: appState.sf(16))
                .padding(.horizontal, appState.sf(4))

            PanelHeaderButton(
                systemImage: appState.isBottomPanelMaximized
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: appState.isBottomPanelMaximized ? "Restore Panel Size" : "Maximize Panel Size"
            ) {
                appState.isBottomPanelMaximized.toggle()
            }

            PanelHeaderButton(systemImage: "xmark", help: "Hide Panel") {
                appState.showBottomPanel = false
            }
        }
        .padding(.horizontal, appState.sf(8))
        .frame(height: headerHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var viewActions: some View {
        if appState.activeBottomPanel == .terminal {
            PanelHeaderButton(systemImage: "plus", help: "New Terminal (⌃⇧`)") {
                appState.newTerminalSession()
            }
            PanelHeaderButton(systemImage: "trash", help: "Kill Terminal") {
                if let id = appState.activeTerminalSessionId {
                    appState.closeTerminalSession(id)
                }
            }
            .disabled(appState.activeTerminalSessionId == nil)
        }
    }

    @ViewBuilder
    private func bottomPanelTab(_ panel: BottomPanel) -> some View {
        let isActive = appState.activeBottomPanel == panel
        let shape = RoundedRectangle(cornerRadius: appState.sf(5), style: .continuous)

        Button {
            appState.activeBottomPanel = panel
        } label: {
            HStack(spacing: appState.sf(5)) {
                Text(panelLabel(panel))
                    .font(.system(size: appState.sf(11.5), weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)

                if panel == .problems, problemCount > 0 {
                    Text("\(problemCount)")
                        .font(.system(size: appState.sf(9.5), weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, appState.sf(5))
                        .padding(.vertical, appState.sf(1))
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .padding(.horizontal, appState.sf(8))
            .padding(.vertical, appState.sf(4))
            .background(shape.fill(Color.primary.opacity(isActive ? 0.1 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var problemCount: Int {
        appState.diagnostics.values.reduce(0) { $0 + $1.count }
    }

    private func panelLabel(_ panel: BottomPanel) -> String {
        switch panel {
        case .terminal:  return "Terminal"
        case .scripts:   return "Scripts"
        case .output:    return "Output"
        case .problems:  return "Problems"
        case .chat:      return "Claude"
        case .sfcclogs:  return "SFCC Logs"
        case .references: return "References"
        case .debugConsole: return "Debug Console"
        }
    }

    // MARK: Panel Content

    @ViewBuilder
    private var panelContent: some View {
        switch appState.activeBottomPanel {
        case .terminal:  TerminalPanelView()
        case .scripts:   ScriptsPanelView()
        case .output:    OutputView()
        case .problems:  ProblemsView()
        case .chat:      ChatView()
        case .sfcclogs:  SFCCLogView()
        case .references: ReferencesPanelView()
        case .debugConsole: DebugConsoleView()
        }
    }
}

// MARK: - TerminalPanelView

/// Hosts the terminal panel's session list (right, as in VS Code) plus the stack of every
/// open session's `TerminalView` (plan.md item 21). Every session's view is
/// kept mounted — never conditionally instantiated — so switching sessions only
/// toggles which one is visible/hit-testable rather than tearing down (and
/// killing) a background shell.
private struct TerminalPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geo in
            // The list may take up to half the panel (unzoomed points); the
            // stored width is only capped at render time.
            let maxList = max(0, (geo.size.width / 2) / appState.uiScale)
            let listWidth = min(appState.terminalListWidth, maxList)

            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !appState.terminalSessions.isEmpty {
                    // Dragging left (negative translation) widens the list.
                    ResizeDivider(axis: .vertical, size: { listWidth }) { base, t in
                        appState.terminalListWidth = min(max(base - t / appState.uiScale, 60), maxList)
                    }
                    TerminalListView()
                        .frame(width: appState.sf(listWidth))
                }
            }
        }
        // Deferred to here so the shell starts in the open folder: at app
        // init no workspace has been restored yet.
        .onAppear { appState.ensureTerminalSession() }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if appState.terminalSessions.isEmpty {
                emptyState
            } else {
                ZStack {
                    ForEach(appState.terminalSessions) { session in
                        let isActive = session.id == appState.activeTerminalSessionId
                        TerminalView(session: session, isActive: isActive, fontSize: appState.sf(13), theme: appState.currentTheme)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: appState.sf(8)) {
            Text("No terminal sessions")
                .font(.system(size: appState.sf(13)))
                .foregroundColor(.secondary)
            Button("New Terminal") {
                appState.newTerminalSession()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// TerminalView is defined in UI/TerminalView.swift (uses SwiftTerm).

// MARK: - PanelHeaderButton

/// Icon button for the panel header, with a hover plate like VS Code's
/// action bar.
private struct PanelHeaderButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.isEnabled) private var isEnabled

    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: appState.sf(11.5)))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.4))
                .frame(width: appState.sf(24), height: appState.sf(22))
                .background(
                    RoundedRectangle(cornerRadius: appState.sf(5), style: .continuous)
                        .fill(Color.primary.opacity(isHovered && isEnabled ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - ProblemsView

struct ProblemsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.diagnostics.isEmpty {
                emptyState
            } else {
                diagnosticsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: appState.sf(8)) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: appState.sf(28)))
                .foregroundColor(.secondary)
            Text("No problems")
                .font(.system(size: appState.sf(13)))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnosticsList: some View {
        List {
            ForEach(Array(appState.diagnostics.keys), id: \.self) { fileURL in
                let fileDiagnostics = appState.diagnostics[fileURL] ?? []
                if !fileDiagnostics.isEmpty {
                    Section {
                        ForEach(fileDiagnostics) { diagnostic in
                            DiagnosticRowView(diagnostic: diagnostic)
                        }
                    } header: {
                        Text(fileURL.lastPathComponent)
                            .font(.system(size: appState.sf(11), weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - DiagnosticRowView

private struct DiagnosticRowView: View {
    let diagnostic: Diagnostic
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .top, spacing: appState.sf(8)) {
            severityIcon
                .font(.system(size: appState.sf(13)))

            VStack(alignment: .leading, spacing: appState.sf(2)) {
                Text(diagnostic.message)
                    .font(.system(size: appState.sf(12)))
                    .foregroundColor(.primary)

                Text("\(diagnostic.fileURL.lastPathComponent):\(diagnostic.line)")
                    .font(.system(size: appState.sf(11)))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, appState.sf(2))
    }

    @ViewBuilder
    private var severityIcon: some View {
        switch diagnostic.severity {
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
        case .information:
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
        case .hint:
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - OutputView

struct OutputView: View {
    @Environment(AppState.self) private var appState
    @State private var scrollProxy: ScrollViewProxy? = nil

    var body: some View {
        VStack(spacing: 0) {
            // toolbar
            HStack(spacing: 0) {
                Spacer()
                if !appState.scriptOutput.isEmpty {
                    Button {
                        appState.scriptOutput = ""
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: appState.sf(12)))
                            .foregroundColor(.secondary)
                            .frame(width: appState.sf(28), height: appState.sf(24))
                    }
                    .buttonStyle(.plain)
                    .help("Clear output")
                }
            }
            .frame(height: appState.sf(24))
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(appState.scriptOutput.isEmpty
                         ? "[Athena] Output log initialised.\n[Athena] Run a script to see output…"
                         : appState.scriptOutput)
                        .font(.system(size: appState.sf(12), design: .monospaced))
                        .foregroundColor(appState.scriptOutput.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(appState.sf(8))
                        .id("bottom")
                }
                .onChange(of: appState.scriptOutput) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
