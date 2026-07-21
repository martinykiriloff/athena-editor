// AthenaApp.swift
// Athena — SwiftUI application entry point.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

@main
struct AthenaApp: App {

    @State private var appState     = AppState()
    @State private var updateService = UpdateService()

    init() {
        // Athena writes to the stdin pipe of several subprocesses it owns
        // (language servers in LSPManager, the debug adapter in DAPClient,
        // prettier in PrettierService). If one of those dies while a write
        // is still queued, the kernel delivers SIGPIPE — whose default
        // disposition terminates this process outright, bypassing Swift
        // error handling entirely (`try?` around the write can't catch a
        // signal). Every other Process/Pipe-heavy tool (Node.js included)
        // ignores SIGPIPE globally for exactly this reason; the write call
        // still surfaces a normal EPIPE error instead of killing the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        // MARK: - Main editor window

        WindowGroup(id: "main") {
            MainWindowView()
                .environment(appState)
                .environment(updateService)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
                }
                .task {
                    await appState.loadSettings()
                    appState.startDiagnosticsConsumer()
                    appState.startFileWatchConsumer()
                    await appState.restoreLastWorkspace()
                    await appState.installKeyMonitor()
                    // Owned by updateService, not this view's .task — see
                    // scheduleAutoCheck's doc comment.
                    updateService.scheduleAutoCheck()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AthenaCommands()
        }

        // MARK: - Preferences / Settings window

        Settings {
            SettingsView()
                .environment(appState)
                .environment(updateService)
        }
    }
}
