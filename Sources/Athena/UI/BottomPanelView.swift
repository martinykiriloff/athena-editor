// BottomPanelView.swift
// Athena — bottom panel: Terminal · Problems · Output.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - BottomPanelView

struct BottomPanelView: View {
    @Environment(AppState.self) private var appState

    private let tabBarHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            tabRow
            Divider()
            panelContent
        }
    }

    // MARK: Tab Row

    private var tabRow: some View {
        HStack(spacing: 0) {
            ForEach(BottomPanel.allCases, id: \.self) { panel in
                bottomPanelTab(panel)
            }
            Spacer()

            // Close button
            Button {
                appState.showBottomPanel = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: appState.sf(11)))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: tabBarHeight)
            }
            .buttonStyle(.plain)
            .help("Close Panel")
        }
        .frame(height: tabBarHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func bottomPanelTab(_ panel: BottomPanel) -> some View {
        let isActive = appState.activeBottomPanel == panel

        Button {
            appState.activeBottomPanel = panel
        } label: {
            Text(panelLabel(panel))
                .font(.system(size: appState.sf(12), weight: isActive ? .medium : .regular))
                .foregroundColor(isActive ? .primary : .secondary)
                .padding(.horizontal, 12)
                .frame(height: tabBarHeight)
                .overlay(alignment: .bottom) {
                    if isActive {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func panelLabel(_ panel: BottomPanel) -> String {
        switch panel {
        case .terminal: return "Terminal"
        case .problems: return "Problems"
        case .output:   return "Output"
        case .chat:     return "Claude"
        }
    }

    // MARK: Panel Content

    @ViewBuilder
    private var panelContent: some View {
        switch appState.activeBottomPanel {
        case .terminal: TerminalView()
        case .problems: ProblemsView()
        case .output:   OutputView()
        case .chat:     ChatView()
        }
    }
}

// TerminalView is defined in UI/TerminalView.swift (uses SwiftTerm).

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
        VStack(spacing: 8) {
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
        HStack(alignment: .top, spacing: 8) {
            severityIcon
                .font(.system(size: appState.sf(13)))

            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.message)
                    .font(.system(size: appState.sf(12)))
                    .foregroundColor(.primary)

                Text("\(diagnostic.fileURL.lastPathComponent):\(diagnostic.line)")
                    .font(.system(size: appState.sf(11)))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
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
    private let placeholder: String = """
        [Athena] Output log initialised.
        [Athena] Waiting for events…
        """

    var body: some View {
        ScrollView {
            Text(placeholder)
                .font(.system(size: appState.sf(12), design: .monospaced))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
