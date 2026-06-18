// AthenaCommands.swift
// Athena — SwiftUI Commands (menu bar) for the main window.
// Swift 6, strict concurrency.
//
// Commands cannot access @Environment directly, so actions are broadcast
// via NotificationCenter and observed by MainWindowView (or any other
// view that subscribes).

import SwiftUI
import AppKit

// MARK: - Notification Names

extension Notification.Name {
    static let athenaOpenFile       = Notification.Name("athena.openFile")
    static let athenaNewTab         = Notification.Name("athena.newTab")
    static let athenaOpenWorkspace  = Notification.Name("athena.openWorkspace")
    static let athenaSave           = Notification.Name("athena.save")
    static let athenaSaveAll        = Notification.Name("athena.saveAll")
    static let athenaToggleSidebar  = Notification.Name("athena.toggleSidebar")
    static let athenaToggleTerminal = Notification.Name("athena.toggleTerminal")
    static let athenaZoomIn         = Notification.Name("athena.zoomIn")
    static let athenaZoomOut        = Notification.Name("athena.zoomOut")
    static let athenaResetZoom      = Notification.Name("athena.resetZoom")
    static let athenaGoToFile       = Notification.Name("athena.goToFile")
    static let athenaGoToLine       = Notification.Name("athena.goToLine")
    static let athenaGoToDefinition = Notification.Name("athena.goToDefinition")
    static let athenaGitRefresh     = Notification.Name("athena.gitRefresh")
    static let athenaGitStageAll    = Notification.Name("athena.gitStageAll")
    static let athenaGitCommit      = Notification.Name("athena.gitCommit")
}

// MARK: - AthenaCommands

struct AthenaCommands: Commands {

    var body: some Commands {
        fileCommands
        viewCommands
        goCommands
        gitCommands
    }

    // MARK: - File Menu

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                NotificationCenter.default.post(name: .athenaNewTab, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            Button("Open File…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.title = "Open File"
                if panel.runModal() == .OK, let url = panel.url {
                    NotificationCenter.default.post(
                        name: .athenaOpenFile,
                        object: url
                    )
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Open Workspace…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = "Open Workspace Folder"
                if panel.runModal() == .OK, let url = panel.url {
                    NotificationCenter.default.post(
                        name: .athenaOpenWorkspace,
                        object: url
                    )
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("Save") {
                NotificationCenter.default.post(name: .athenaSave, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save All") {
                NotificationCenter.default.post(name: .athenaSaveAll, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    // MARK: - View Menu

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandMenu("View") {
            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .athenaToggleSidebar, object: nil)
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("Toggle Terminal") {
                NotificationCenter.default.post(name: .athenaToggleTerminal, object: nil)
            }
            .keyboardShortcut("`", modifiers: .control)

            Divider()

            Button("Zoom In") {
                NotificationCenter.default.post(name: .athenaZoomIn, object: nil)
            }
            .keyboardShortcut("=", modifiers: .command)

            Button("Zoom Out") {
                NotificationCenter.default.post(name: .athenaZoomOut, object: nil)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Reset Zoom") {
                NotificationCenter.default.post(name: .athenaResetZoom, object: nil)
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }

    // MARK: - Go Menu

    @CommandsBuilder
    private var goCommands: some Commands {
        CommandMenu("Go") {
            Button("Go to File…") {
                NotificationCenter.default.post(name: .athenaGoToFile, object: nil)
            }
            .keyboardShortcut("p", modifiers: .command)

            Button("Go to Line…") {
                NotificationCenter.default.post(name: .athenaGoToLine, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .control])

            Button("Go to Definition") {
                NotificationCenter.default.post(name: .athenaGoToDefinition, object: nil)
            }
            // F12 = Unicode private-use 0xF70B (macOS function-key encoding).
            .keyboardShortcut(KeyEquivalent("\u{F70B}"), modifiers: [])
        }
    }

    // MARK: - Git Menu

    @CommandsBuilder
    private var gitCommands: some Commands {
        CommandMenu("Git") {
            Button("Refresh Status") {
                NotificationCenter.default.post(name: .athenaGitRefresh, object: nil)
            }

            Button("Stage All") {
                NotificationCenter.default.post(name: .athenaGitStageAll, object: nil)
            }

            Button("Commit…") {
                NotificationCenter.default.post(name: .athenaGitCommit, object: nil)
            }
        }
    }
}
