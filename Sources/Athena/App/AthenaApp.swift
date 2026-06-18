// AthenaApp.swift
// Athena — SwiftUI application entry point.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

@main
struct AthenaApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        // MARK: - Main editor window

        WindowGroup {
            MainWindowView()
                .environment(appState)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
                }
                .task {
                    await appState.loadSettings()
                    await appState.restoreLastWorkspace()
                    await appState.installKeyMonitor()
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
        }
    }
}
