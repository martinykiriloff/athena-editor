// AppState.swift
// Athena — central observable application state, bound to the main actor.
// Swift 6, strict concurrency.

import SwiftUI
import Foundation
@preconcurrency import AppKit

@Observable
@MainActor
final class AppState {

    // MARK: - Services (actors)

    let fileService: FileService
    let gitService: GitService
    let claudeService: ClaudeService
    let claudeCLIService: ClaudeCLIService
    let searchService: SearchService
    let settingsService: SettingsService
    let lspManager: LSPManager
    let keyBindingService: KeyBindingService
    let blameService: GitBlameService

    // MARK: - UI State

    var workspace: WorkspaceModel?
    var openTabs: [TabModel] = []
    var activeTabId: UUID?
    var fileTree: [FileNode] = []
    var gitStatus: GitStatus = GitStatus()
    var searchResults: [SearchResult] = []
    var diagnostics: [URL: [Diagnostic]] = [:]
    var chatMessages: [ChatMessage] = []
    var isStreaming: Bool = false
    var activeSidebarPanel: SidebarPanel = .files
    var showSidebar: Bool = true
    var showBottomPanel: Bool = false
    var activeBottomPanel: BottomPanel = .terminal
    var sidebarWidth: CGFloat = 260
    var bottomPanelHeight: CGFloat = 220
    var statusMessage: String = ""
    var searchQuery: String = ""
    var commitMessage: String = ""
    var currentTheme: EditorTheme = .darcula
    var dbConnections: [DBConnection] = []
    var activeClaudeAccount: ClaudeAccount = .personal
    var claudeMessages: [ClaudeMessage] = []
    var claudeIsStreaming: Bool = false
    var showClaudePanel: Bool = false
    var claudePanelWidth: CGFloat = 340
    var keyBindings: [KeyBinding] = KeyBinding.vscodeDefaults
    var showQuickOpen: Bool = false

    // Blame data keyed by file path.
    var blameCache: [String: [Int: BlameLine]] = [:]

    // MARK: - Editor settings (mirrored from SettingsService on launch)
    var editorFontSize:          CGFloat = 14
    var editorFontFamily:        String  = "JetBrains Mono"
    var editorFontLigatures:     Bool    = true
    var editorLineHeight:        CGFloat = 1.0
    var editorTabSize:           Int     = 4
    var editorInsertSpaces:      Bool    = true
    var editorWordWrap:          Bool    = false
    var editorLineNumbers:       Bool    = true
    var editorRenderWhitespace:  Bool    = true
    var editorMinimapEnabled:    Bool    = true
    var editorCursorStyle:       String  = "line"
    var editorCursorBlink:       String  = "blink"
    var editorScrollBeyondLastLine: Bool = true
    var editorFormatOnSave:      Bool    = false
    var editorAutoIndent:        Bool    = true
    var editorDetectIndentation: Bool    = true

    // MARK: - Computed

    var activeTab: TabModel? {
        openTabs.first { $0.id == activeTabId }
    }

    /// Flat, sorted list of every non-directory file in the workspace tree.
    var allFiles: [FileNode] {
        var result: [FileNode] = []
        func collect(_ nodes: [FileNode]) {
            for node in nodes {
                if !node.isDirectory { result.append(node) }
                if let children = node.children { collect(children) }
            }
        }
        collect(fileTree)
        return result.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - Init

    @ObservationIgnored private var keyEventMonitor: Any? = nil

    init(
        fileService: FileService = FileService(),
        gitService: GitService = GitService(),
        claudeService: ClaudeService = ClaudeService(),
        claudeCLIService: ClaudeCLIService = ClaudeCLIService(),
        searchService: SearchService = SearchService(),
        settingsService: SettingsService = SettingsService(),
        lspManager: LSPManager = LSPManager(),
        keyBindingService: KeyBindingService = KeyBindingService(),
        blameService: GitBlameService = GitBlameService()
    ) {
        self.fileService = fileService
        self.gitService = gitService
        self.claudeService = claudeService
        self.claudeCLIService = claudeCLIService
        self.searchService = searchService
        self.settingsService = settingsService
        self.lspManager = lspManager
        self.keyBindingService = keyBindingService
        self.blameService = blameService
    }

    // MARK: - Methods

    /// Opens a file URL in a new tab, or activates the existing tab if already open.
    func openFile(_ url: URL) async {
        // If the file is already open, just activate it.
        if let existing = openTabs.first(where: { $0.fileURL == url }) {
            activeTabId = existing.id
            return
        }

        do {
            let content = try await fileService.readFile(url)
            var tab = TabModel(title: url.lastPathComponent)
            tab.fileURL = url
            tab.content = content
            tab.language = Language.detect(from: url)
            tab.isDirty = false
            openTabs.append(tab)
            activeTabId = tab.id
            statusMessage = "Opened \(url.lastPathComponent)"
        } catch {
            statusMessage = "Error opening \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Closes the tab with the given ID, activating an adjacent tab if needed.
    func closeTab(_ id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }

        openTabs.remove(at: index)

        // If we just closed the active tab, select an adjacent one.
        if activeTabId == id {
            if openTabs.isEmpty {
                activeTabId = nil
            } else {
                // Prefer the tab now at the same index; fall back to the last tab.
                let newIndex = min(index, openTabs.count - 1)
                activeTabId = openTabs[newIndex].id
            }
        }
    }

    /// Opens a workspace directory, builds the file tree, and refreshes Git status.
    func openWorkspace(_ url: URL) async {
        workspace = WorkspaceModel(rootURL: url)
        statusMessage = "Opening workspace \(url.lastPathComponent)…"

        do {
            fileTree = try await fileService.buildFileTree(url)
        } catch {
            statusMessage = "Error building file tree: \(error.localizedDescription)"
        }

        await refreshGitStatus()
        statusMessage = url.lastPathComponent

        try? await settingsService.setValue(url.path, for: "lastWorkspacePath")
    }

    // MARK: - Git Blame

    /// Loads (or returns cached) blame data for the file in `tab`.
    /// Only runs when a `.git` directory exists at the workspace root.
    func loadBlame(for tab: TabModel) async {
        guard let fileURL = tab.fileURL,
              let ws = workspace else { return }
        let gitDir = ws.rootURL.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else { return }
        let blame = await blameService.blame(fileURL: fileURL, workspaceURL: ws.rootURL)
        blameCache[fileURL.path] = blame
    }

    func invalidateBlame(for fileURL: URL) {
        blameCache.removeValue(forKey: fileURL.path)
        Task { await blameService.invalidate(fileURL: fileURL) }
    }

    // MARK: - Settings persistence

    /// Loads all persisted settings into AppState. Call once at app launch.
    func loadSettings() async {
        async let fs   = settingsService.value(for: "editorFontSize",          default: 14.0)
        async let ff   = settingsService.value(for: "editorFontFamily",        default: "JetBrains Mono")
        async let fl   = settingsService.value(for: "editorFontLigatures",     default: true)
        async let lh   = settingsService.value(for: "editorLineHeight",        default: 1.0)
        async let ts   = settingsService.value(for: "editorTabSize",           default: 4)
        async let isp  = settingsService.value(for: "editorInsertSpaces",      default: true)
        async let ww   = settingsService.value(for: "editorWordWrap",          default: false)
        async let ln   = settingsService.value(for: "editorLineNumbers",       default: true)
        async let rws  = settingsService.value(for: "editorRenderWhitespace",  default: true)
        async let mm   = settingsService.value(for: "editorMinimapEnabled",    default: true)
        async let cs   = settingsService.value(for: "editorCursorStyle",       default: "line")
        async let cb   = settingsService.value(for: "editorCursorBlink",       default: "blink")
        async let sbl  = settingsService.value(for: "editorScrollBeyondLastLine", default: true)
        async let fos  = settingsService.value(for: "editorFormatOnSave",      default: false)
        async let ai   = settingsService.value(for: "editorAutoIndent",        default: true)
        async let di   = settingsService.value(for: "editorDetectIndentation", default: true)
        async let th   = settingsService.value(for: "theme",                   default: "darcula")

        editorFontSize          = await fs
        editorFontFamily        = await ff
        editorFontLigatures     = await fl
        editorLineHeight        = await lh
        editorTabSize           = await ts
        editorInsertSpaces      = await isp
        editorWordWrap          = await ww
        editorLineNumbers       = await ln
        editorRenderWhitespace  = await rws
        editorMinimapEnabled    = await mm
        editorCursorStyle       = await cs
        editorCursorBlink       = await cb
        editorScrollBeyondLastLine = await sbl
        editorFormatOnSave      = await fos
        editorAutoIndent        = await ai
        editorDetectIndentation = await di
        currentTheme            = EditorTheme.named(await th)
    }

    /// Persists a single setting value, ignoring errors.
    func persistSetting<T: Codable & Sendable>(_ value: T, for key: String) {
        Task { try? await settingsService.setValue(value, for: key) }
    }

    /// Reopens the last workspace if one was saved; called on app launch.
    func restoreLastWorkspace() async {
        let path = await settingsService.value(for: "lastWorkspacePath", default: "")
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        await openWorkspace(url)
    }

    /// Saves the content of the currently active tab to disk.
    func saveActiveTab() async {
        guard
            var tab = activeTab,
            let url = tab.fileURL
        else { return }

        do {
            try await fileService.writeFile(url, content: tab.content)
            // Update isDirty on the stored tab model.
            if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
                openTabs[index].isDirty = false
                tab = openTabs[index]
            }
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            statusMessage = "Error saving \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Refreshes the Git status for the current workspace.
    func refreshGitStatus() async {
        guard let workspace else { return }

        do {
            gitStatus = try await gitService.status(at: workspace.rootURL)
        } catch {
            statusMessage = "Git error: \(error.localizedDescription)"
        }
    }

    /// Updates the text content of a tab and marks it as dirty.
    func updateTabContent(_ id: UUID, content: String) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        openTabs[index].content = content
        openTabs[index].isDirty = true
    }

    // MARK: - Claude sidebar

    /// Switches the active Claude account, aborting any in-flight request and
    /// clearing the conversation (each CLI maintains its own session).
    func switchClaudeAccount(_ account: ClaudeAccount) async {
        guard account != activeClaudeAccount else { return }
        await claudeCLIService.abort()
        claudeIsStreaming = false
        claudeMessages = []
        activeClaudeAccount = account
    }

    /// Appends a user message, spawns the CLI, and streams the response.
    func sendClaudeMessage(_ text: String) async {
        guard !claudeIsStreaming else { return }

        claudeMessages.append(ClaudeMessage(role: .user, content: text))

        let assistantMsg = ClaudeMessage(role: .assistant, content: "", isStreaming: true)
        claudeMessages.append(assistantMsg)
        let assistantId = assistantMsg.id

        claudeIsStreaming = true

        let prompt  = buildClaudePrompt()
        let command = activeClaudeAccount.command
        let stream  = await claudeCLIService.stream(prompt: prompt, command: command)

        for await chunk in stream {
            guard let idx = claudeMessages.firstIndex(where: { $0.id == assistantId }) else { break }
            claudeMessages[idx].content += chunk
        }

        if let idx = claudeMessages.firstIndex(where: { $0.id == assistantId }) {
            claudeMessages[idx].isStreaming = false
        }
        claudeIsStreaming = false
    }

    // MARK: - Key bindings

    /// Loads persisted overrides and installs the global key event monitor.
    func installKeyMonitor() async {
        keyBindings = await keyBindingService.load()
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modRaw  = event.modifierFlags.rawValue
            let chars   = event.charactersIgnoringModifiers ?? ""
            let consumed = MainActor.assumeIsolated {
                self?.dispatchKeyInfo(keyCode: keyCode, modRaw: modRaw, chars: chars) ?? false
            }
            return consumed ? nil : event
        }
    }

    /// Updates a single binding and persists the change.
    func setKeyBinding(action: KeyAction, combo: KeyCombo?) async {
        guard let idx = keyBindings.firstIndex(where: { $0.action == action }) else { return }
        let defaultCombo = KeyBinding.vscodeDefaults.first(where: { $0.action == action })?.combo
        keyBindings[idx].combo       = combo
        keyBindings[idx].isCustomized = (combo != defaultCombo)
        await keyBindingService.save(bindings: keyBindings)
    }

    /// Resets a single binding to its VS Code default.
    func resetKeyBinding(action: KeyAction) async {
        let def = KeyBinding.vscodeDefaults.first(where: { $0.action == action })
        await setKeyBinding(action: action, combo: def?.combo)
        if let idx = keyBindings.firstIndex(where: { $0.action == action }) {
            keyBindings[idx].isCustomized = false
        }
        await keyBindingService.save(bindings: keyBindings)
    }

    /// Resets all bindings to VS Code defaults.
    func resetAllKeyBindings() async {
        keyBindings = KeyBinding.vscodeDefaults
        await keyBindingService.save(bindings: keyBindings)
    }

    private func dispatchKeyInfo(keyCode: UInt16, modRaw: UInt, chars: String) -> Bool {
        guard let combo = KeyCombo.from(keyCode: keyCode, modRaw: modRaw, chars: chars),
              let binding = keyBindings.first(where: { $0.combo == combo })
        else { return false }
        Task { await self.perform(binding.action) }
        return true
    }

    /// The single dispatch point for every bindable action. Called both by the
    /// keybinding monitor (keyboard) and by menu commands (clicks), so a binding
    /// and its menu item always do exactly the same thing.
    func perform(_ action: KeyAction) async {
        switch action {
        case .saveFile:
            await saveActiveTab()
        case .newFile:
            openNewTab()
        case .closeTab:
            if let id = activeTabId { closeTab(id) }
        case .toggleSidebar:
            showSidebar.toggle()
        case .toggleTerminal:
            toggleTerminal()
        case .showExplorer:
            activateSidebarPanel(.files)
        case .showSourceControl:
            activateSidebarPanel(.git)
        case .showSearch:
            activateSidebarPanel(.search)
        case .showDatabase:
            activateSidebarPanel(.database)
        case .showClaude:
            showClaudePanel.toggle()
        case .quickOpen:
            presentQuickOpen()
        case .nextTab:
            cycleTab(forward: true)
        case .previousTab:
            cycleTab(forward: false)
        // Editor-level actions are forwarded to the active text view, which
        // owns the selection and undo stack.
        case .findInFile:
            postEditorCommand(.find)
        case .goToLine:
            postEditorCommand(.goToLine)
        case .toggleComment:
            postEditorCommand(.toggleComment)
        case .indentLine:
            postEditorCommand(.indent)
        case .outdentLine:
            postEditorCommand(.outdent)
        }
    }

    /// Forwards an editor command to the active EditorView's coordinator.
    private func postEditorCommand(_ command: EditorCommand) {
        NotificationCenter.default.post(name: .athenaEditorCommand, object: command)
    }

    private func presentQuickOpen() {
        showQuickOpen = true
    }

    /// Saves every open tab that has unsaved changes.
    func saveAllTabs() async {
        for tab in openTabs where tab.isDirty {
            guard let url = tab.fileURL else { continue }
            do {
                try await fileService.writeFile(url, content: tab.content)
                if let i = openTabs.firstIndex(where: { $0.id == tab.id }) {
                    openTabs[i].isDirty = false
                }
            } catch {
                statusMessage = "Error saving \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        statusMessage = "Saved all files"
    }

    /// Adjusts the editor font size (zoom in/out) and persists it.
    func adjustFontSize(by delta: CGFloat) {
        editorFontSize = min(48, max(8, editorFontSize + delta))
        persistSetting(editorFontSize, for: "editorFontSize")
    }

    /// Resets the editor font size to the default and persists it.
    func resetFontSize() {
        editorFontSize = 14
        persistSetting(editorFontSize, for: "editorFontSize")
    }

    func openNewTab() {
        let tab = TabModel.untitled()
        openTabs.append(tab)
        activeTabId = tab.id
    }

    /// Toggles the integrated terminal panel — shows it (and selects the
    /// Terminal tab) if hidden, hides it if it's already the active panel.
    /// Bound to ⌃` (the VS Code "Toggle Terminal" shortcut).
    func toggleTerminal() {
        toggleBottomPanel(.terminal)
    }

    private func toggleBottomPanel(_ panel: BottomPanel) {
        if showBottomPanel && activeBottomPanel == panel {
            showBottomPanel = false
        } else {
            activeBottomPanel = panel
            showBottomPanel   = true
        }
    }

    private func activateSidebarPanel(_ panel: SidebarPanel) {
        if activeSidebarPanel == panel {
            showSidebar.toggle()
        } else {
            activeSidebarPanel = panel
            showSidebar        = true
        }
    }

    private func cycleTab(forward: Bool) {
        guard !openTabs.isEmpty else { return }
        let current  = openTabs.firstIndex(where: { $0.id == activeTabId }) ?? 0
        let next     = forward
            ? (current + 1) % openTabs.count
            : (current - 1 + openTabs.count) % openTabs.count
        activeTabId = openTabs[next].id
    }

    /// Builds a prompt that includes recent conversation history as context.
    private func buildClaudePrompt() -> String {
        // All messages except the empty assistant placeholder we just appended.
        let messages = claudeMessages.dropLast()
        guard messages.count > 1 else {
            return messages.last?.content ?? ""
        }
        // Keep the last 10 messages (5 turns) for context.
        return messages.suffix(10).map { msg -> String in
            let role = msg.role == .user ? "Human" : "Assistant"
            return "\(role): \(msg.content)"
        }.joined(separator: "\n\n")
    }
}
