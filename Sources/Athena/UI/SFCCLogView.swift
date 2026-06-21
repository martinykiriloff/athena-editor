// SFCCLogView.swift
// Athena — SFCC sandbox log viewer (bottom panel).
// Swift 6, strict concurrency.

import SwiftUI

struct SFCCLogView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logContent
        }
        .task { await appState.startSFCCLogPolling() }
        .onDisappear { appState.stopSFCCLogPolling() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let conn = appState.sfccConnections.first(where: { $0.isActive }) {
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
}
