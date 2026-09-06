// SFCCLogView.swift
// Athena — SFCC bottom panel: sandbox log viewer + upload activity feed.
// Swift 6, strict concurrency.

import SwiftUI

struct SFCCLogView: View {
    @Environment(AppState.self) private var appState

    private enum Pane: String, CaseIterable {
        case sandboxLogs = "Sandbox Logs"
        case uploads     = "Uploads"
    }
    @State private var pane: Pane = .sandboxLogs

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch pane {
            case .sandboxLogs: logContent
            case .uploads:     uploadsContent
            }
        }
        .task { await appState.startSFCCLogPolling() }
        .onDisappear { appState.stopSFCCLogPolling() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Pane", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if let conn = appState.sfccConnections.first(where: { $0.isActive }) {
                switch pane {
                case .sandboxLogs: sandboxLogControls(conn)
                case .uploads:     uploadControls
                }

                Spacer()

                Text(conn.hostname)
                    .font(.system(size: appState.sf(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No active SFCC sandbox — activate one in the SFCC sidebar panel.")
                    .font(.system(size: appState.sf(12)))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func sandboxLogControls(_ conn: SFCCConnection) -> some View {
        if !appState.sfccAvailableLogs.isEmpty {
            Picker("Log", selection: Binding(
                get: { appState.sfccSelectedLog },
                set: { log in
                    appState.sfccSelectedLog = log
                    appState.sfccLogContent  = ""
                    appState.sfccLogOffset   = 0
                }
            )) {
                ForEach(appState.sfccAvailableLogs, id: \.self) { log in
                    Text(log).tag(log)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)
        } else {
            Text("Loading logs…")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(.secondary)
        }

        Button {
            Task { await appState.refreshSFCCLogs(for: conn) }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Refresh log list")

        Button {
            appState.sfccLogContent = ""
            appState.sfccLogOffset  = 0
        } label: {
            Image(systemName: "trash")
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear log")
    }

    @ViewBuilder
    private var uploadControls: some View {
        Text("\(appState.sfccUploadLog.count) transfers")
            .font(.system(size: appState.sf(11)))
            .foregroundStyle(.secondary)

        Button {
            appState.clearSFCCUploadLog()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear upload history (the on-disk log file is kept)")
    }

    // MARK: Log content

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(appState.sfccLogContent.isEmpty
                     ? "[Waiting for log output…]"
                     : appState.sfccLogContent)
                    .font(.system(size: appState.sf(11), design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("logEnd")
            }
            .onChange(of: appState.sfccLogContent) { _, _ in
                proxy.scrollTo("logEnd", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Uploads content

    private var uploadsContent: some View {
        Group {
            if appState.sfccUploadLog.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: appState.sf(28)))
                        .foregroundStyle(.tertiary)
                    Text("No uploads yet")
                        .font(.system(size: appState.sf(13)))
                        .foregroundStyle(.secondary)
                    Text("While a sandbox is active, every file saved or changed under the cartridges folder uploads automatically and shows up here.")
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.sfccUploadLog) { record in
                            SFCCUploadRow(record: record)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - SFCCUploadRow

private struct SFCCUploadRow: View {
    let record: SFCCUploadRecord
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.relativePath)
                    .font(.system(size: appState.sf(11), design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let message = record.failureMessage {
                    Text(message)
                        .font(.system(size: appState.sf(10)))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            switch record.kind {
            case .delete:
                Text("deleted")
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.orange)
            case .cartridge:
                Text("full cartridge")
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.blue)
            case .upload:
                EmptyView()
            }

            Text("\(record.connectionName)/\(record.codeVersion)")
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Text(record.date.formatted(date: .omitted, time: .standard))
                .font(.system(size: appState.sf(10), design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .help(record.failureMessage ?? record.relativePath)
    }

    private var iconName: String {
        if record.failureMessage != nil { return "exclamationmark.circle.fill" }
        switch record.kind {
        case .upload:    return "arrow.up.circle.fill"
        case .delete:    return "trash.circle.fill"
        case .cartridge: return "shippingbox.circle.fill"
        }
    }

    private var iconColor: Color {
        if record.failureMessage != nil { return .red }
        switch record.kind {
        case .upload:    return .green
        case .delete:    return .orange
        case .cartridge: return .blue
        }
    }
}
