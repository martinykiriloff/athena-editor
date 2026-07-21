// AthenaApp.swift
// Athena — SwiftUI application entry point.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

@main
struct AthenaApp: App {

    @State private var appState     = AppState()
    @State private var updateService = UpdateService()

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
