// DebugSidebarView.swift
// Athena — "Run & Debug" sidebar panel.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - DebugSidebarView

struct DebugSidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            launchSection
            Divider()
            if appState.debugState != .idle && appState.debugState != .stopped {
                debugContent
            } else {
                breakpointsSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: appState.workspace?.rootURL) {
            appState.loadLaunchConfigs()
        }
    }

    // MARK: Launch section

    private var launchSection: some View {
        VStack(spacing: 6) {
            // Config picker
            if !appState.launchConfigs.isEmpty {
                Picker("", selection: Bindable(appState).selectedLaunchConfigId) {
                    ForEach(appState.launchConfigs) { config in
                        Label(config.name, systemImage: configIcon(config.type))
                            .tag(Optional(config.id))
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: appState.sf(12)))
                .padding(.horizontal, 8)
            }

            // Start / Stop button
            HStack(spacing: 8) {
                if appState.debugState == .idle || appState.debugState == .stopped {
                    Button {
                        Task { await appState.startDebugging() }
                    } label: {
                        Label("Start Debugging", systemImage: "play.fill")
                            .font(.system(size: appState.sf(12)))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.launchConfigs.isEmpty)
                } else {
                    Button(role: .destructive) {
                        Task { await appState.stopDebugging() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: appState.sf(12)))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 8)

            // Status pill
            statusPill
        }
        .padding(.vertical, 8)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            Text(stateLabel)
                .font(.system(size: appState.sf(11)))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var stateColor: Color {
        switch appState.debugState {
        case .idle:                 return .secondary
        case .launching:            return .yellow
        case .running:              return .green
        case .paused:               return .orange
        case .stopped:              return .red
        }
    }

    private var stateLabel: String {
        switch appState.debugState {
        case .idle:                 return "Not running"
        case .launching:            return "Launching…"
        case .running:              return "Running"
        case .paused(let reason):   return "Paused — \(reason)"
        case .stopped:              return "Stopped"
        }
    }

    // MARK: Active debug content (call stack + variables)

    private var debugContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                callStackSection
                Divider().padding(.vertical, 4)
                variablesSection
                Divider().padding(.vertical, 4)
                breakpointsSection
            }
        }
    }

    // MARK: Call Stack

    private var callStackSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("CALL STACK")
            if appState.debugStackFrames.isEmpty {
                Text(appState.debugState == .running ? "Running…" : "No frames")
                    .font(.system(size: appState.sf(11)))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.debugStackFrames) { frame in
                    frameRow(frame)
                }
            }
        }
    }

    private func frameRow(_ frame: DebugStackFrame) -> some View {
        let isActive = frame.id == appState.debugStackFrames.first?.id
        return HStack(spacing: 6) {
            if isActive {
                Image(systemName: "arrow.right")
                    .font(.system(size: appState.sf(9)))
                    .foregroundColor(.orange)
            } else {
                Color.clear.frame(width: 12)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(frame.name)
                    .font(.system(size: appState.sf(12)))
                    .foregroundColor(isActive ? .primary : .secondary)
                    .lineLimit(1)
                if let url = frame.sourceURL {
                    Text("\(url.lastPathComponent):\(frame.line)")
                        .font(.system(size: appState.sf(10)))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: Variables

    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("VARIABLES")
            if appState.debugVariables.isEmpty {
                Text("No variables")
                    .font(.system(size: appState.sf(11)))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.debugVariables.prefix(50)) { variable in
                    variableRow(variable)
                }
            }
        }
    }

    private func variableRow(_ variable: DebugVariable) -> some View {
        HStack(spacing: 6) {
            Text(variable.name)
                .font(.system(size: appState.sf(12)))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
            Text(variable.value)
                .font(.system(size: appState.sf(12), design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let type = variable.type {
                Text(type)
                    .font(.system(size: appState.sf(10)))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: Breakpoints list

    private var breakpointsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionHeader("BREAKPOINTS")
                Spacer()
                if !appState.debugBreakpoints.isEmpty {
                    Button {
                        appState.debugBreakpoints.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: appState.sf(11)))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove all breakpoints")
                    .padding(.trailing, 8)
                }
            }

            let allBreakpoints = appState.debugBreakpoints
                .flatMap { file, lines in lines.sorted().map { (file, $0) } }
                .sorted { ($0.0, $0.1) < ($1.0, $1.1) }

            if allBreakpoints.isEmpty {
                Text("No breakpoints set.\nClick in the gutter to add one.")
                    .font(.system(size: appState.sf(11)))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(allBreakpoints.enumerated()), id: \.offset) { _, bp in
                    breakpointRow(filePath: bp.0, line: bp.1)
                }
            }
        }
    }

    private func breakpointRow(filePath: String, line: Int) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: filePath).lastPathComponent)
                    .font(.system(size: appState.sf(12)))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("Line \(line)")
                    .font(.system(size: appState.sf(10)))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                appState.toggleBreakpoint(filePath: filePath, line: line)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: appState.sf(10)))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: Helpers

    private func configIcon(_ type: String) -> String {
        switch type {
        case "node-cdp", "node", "pwa-node", "typescript": return "server.rack"
        case "chrome", "nextjs":                            return "globe"
        case "python":                                      return "terminal"
        case "lldb", "swift":                               return "hammer"
        default:                                            return "play.circle"
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: appState.sf(10), weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(0.5)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
