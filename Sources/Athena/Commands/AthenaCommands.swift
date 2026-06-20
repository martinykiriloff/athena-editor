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
    /// Generic menu→app dispatch carrying a `KeyAction` as its `object`. Lets
    /// menu commands run the exact same code path as the keybinding monitor.
    static let athenaPerformAction  = Notification.Name("athena.performAction")
    /// Editor-level command carrying an `EditorCommand` as its `object`.
    static let athenaEditorCommand  = Notification.Name("athena.editorCommand")

    static let athenaOpenFile       = Notification.Name("athena.openFile")
    static let athenaOpenWorkspace  = Notification.Name("athena.openWorkspace")
    static let athenaSaveAll        = Notification.Name("athena.saveAll")
    static let athenaZoomIn         = Notification.Name("athena.zoomIn")
    static let athenaZoomOut        = Notification.Name("athena.zoomOut")
    static let athenaResetZoom      = Notification.Name("athena.resetZoom")
    static let athenaGitRefresh     = Notification.Name("athena.gitRefresh")
    static let athenaGitStageAll    = Notification.Name("athena.gitStageAll")
    static let athenaGitCommit      = Notification.Name("athena.gitCommit")
    static let athenaCheckForUpdates = Notification.Name("athena.checkForUpdates")
}

// MARK: - Menu action helper

private func performAction(_ action: KeyAction) {
    NotificationCenter.default.post(name: .athenaPerformAction, object: action)
}

// MARK: - AthenaCommands

struct AthenaCommands: Commands {

    var body: some Commands {
        appInfoCommands
        fileCommands
        viewCommands
        goCommands
        gitCommands
    }

    // MARK: - App Menu (injected after "About Athena")

    @CommandsBuilder
    private var appInfoCommands: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                NotificationCenter.default.post(name: .athenaCheckForUpdates, object: nil)
            }
            Divider()
        }
    }

    // MARK: - File Menu

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            // New File (⌘N) and Close Editor (⌘W) are owned by the keybinding
            // monitor; they're intentionally not given menu key-equivalents so
            // they don't shadow it. Menu clicks route through the same action.
            Button("New File") {
                performAction(.newFile)
            }

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

            // Save (⌘S) is owned by the keybinding monitor — no menu shortcut.
            Button("Save") {
                performAction(.saveFile)
            }

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
            // ⌘B and ⌃` are owned by the keybinding monitor (so it isn't
            // shadowed by the menu); clicks route through the same action.
            Button("Toggle Sidebar") {
                performAction(.toggleSidebar)
            }

            Button("Toggle Terminal") {
                performAction(.toggleTerminal)
            }

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
            // ⌘P and ⌘⌃G are owned by the keybinding monitor; clicks route
            // through the same actions.
            Button("Go to File…") {
                performAction(.quickOpen)
            }

            Button("Go to Line…") {
                performAction(.goToLine)
            }
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
