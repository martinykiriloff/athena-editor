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

    static let athenaOpenFile        = Notification.Name("athena.openFile")
    static let athenaOpenWorkspace   = Notification.Name("athena.openWorkspace")
    static let athenaSaveAll         = Notification.Name("athena.saveAll")
    static let athenaSaveAs          = Notification.Name("athena.saveAs")
    static let athenaRevertFile      = Notification.Name("athena.revertFile")
    static let athenaCloseFolder     = Notification.Name("athena.closeFolder")
    static let athenaNewWindow       = Notification.Name("athena.newWindow")
    static let athenaZoomIn          = Notification.Name("athena.zoomIn")
    static let athenaZoomOut         = Notification.Name("athena.zoomOut")
    static let athenaResetZoom       = Notification.Name("athena.resetZoom")
    static let athenaGitRefresh      = Notification.Name("athena.gitRefresh")
    static let athenaGitStageAll     = Notification.Name("athena.gitStageAll")
    static let athenaGitCommit       = Notification.Name("athena.gitCommit")
    static let athenaCheckForUpdates = Notification.Name("athena.checkForUpdates")
}

// MARK: - Menu action helper

private func performAction(_ action: KeyAction) {
    NotificationCenter.default.post(name: .athenaPerformAction, object: action)
}

// MARK: - AthenaCommands

struct AthenaCommands: Commands {

    // Persisted via UserDefaults so Commands (which can't read @Environment)
    // can bind the Auto Save toggle and read the recent-paths list.
    @AppStorage("athenaAutoSave")    private var autoSave   = false
    @AppStorage("athenaRecentPaths") private var recentRaw  = ""

    private var recentURLs: [URL] {
        recentRaw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func isDir(_ path: String) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }

    var body: some Commands {
        appInfoCommands
        fileCommands
        findCommands
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

            // ── New ────────────────────────────────────────────────────────
            Button("New Text File") {
                performAction(.newFile)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New File…") {
                // Let the user name and locate the file before opening it.
                let panel = NSSavePanel()
                panel.title = "New File"
                panel.nameFieldStringValue = "Untitled.txt"
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    do {
                        try "".write(to: url, atomically: true, encoding: .utf8)
                        NotificationCenter.default.post(name: .athenaOpenFile, object: url)
                    } catch { }
                }
            }
            .keyboardShortcut("n", modifiers: [.control, .option, .command])

            Button("New Window") {
                NotificationCenter.default.post(name: .athenaNewWindow, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            // ── Open ───────────────────────────────────────────────────────
            Button("Open…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.title = "Open File"
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    NotificationCenter.default.post(name: .athenaOpenFile, object: url)
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Open Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = "Open Folder"
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    NotificationCenter.default.post(name: .athenaOpenWorkspace, object: url)
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Menu("Open Recent") {
                if recentURLs.isEmpty {
                    Text("No Recent Items")
                } else {
                    ForEach(recentURLs, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            if isDir(url.path) {
                                NotificationCenter.default.post(name: .athenaOpenWorkspace, object: url)
                            } else {
                                NotificationCenter.default.post(name: .athenaOpenFile, object: url)
                            }
                        }
                    }
                    Divider()
                    Button("Clear Recent") {
                        UserDefaults.standard.set("", forKey: "athenaRecentPaths")
                    }
                }
            }

            Divider()

            // ── Save ───────────────────────────────────────────────────────
            // ⌘S is owned by the keybinding monitor; click routes the same way.
            Button("Save") {
                performAction(.saveFile)
            }

            Button("Save As…") {
                NotificationCenter.default.post(name: .athenaSaveAs, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Save All") {
                NotificationCenter.default.post(name: .athenaSaveAll, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Divider()

            // ── Auto Save toggle ───────────────────────────────────────────
            Toggle("Auto Save", isOn: $autoSave)

            Divider()

            // ── File lifecycle ─────────────────────────────────────────────
            Button("Revert File") {
                NotificationCenter.default.post(name: .athenaRevertFile, object: nil)
            }

            // ⌘W is owned by the keybinding monitor; click routes the same way.
            Button("Close Editor") {
                performAction(.closeTab)
            }

            Button("Close Folder") {
                NotificationCenter.default.post(name: .athenaCloseFolder, object: nil)
            }

            Button("Close Window") {
                NSApplication.shared.keyWindow?.close()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }

    // MARK: - Find Menu

    @CommandsBuilder
    private var findCommands: some Commands {
        CommandMenu("Find") {
            // ⌘F and ⌥⌘F are owned by the keybinding monitor (so they aren't
            // shadowed by the menu); clicks route through the same actions.
            Button("Find…") {
                performAction(.findInFile)
            }

            Button("Find and Replace…") {
                performAction(.findAndReplace)
            }
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
            // ⌘P, ⇧⌘P, and ⌘⌃G are owned by the keybinding monitor; clicks
            // route through the same actions.
            Button("Go to File…") {
                performAction(.quickOpen)
            }

            Button("Command Palette…") {
                performAction(.commandPalette)
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
