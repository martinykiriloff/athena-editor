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
    let keychainService: KeychainService
    let lspManager: LSPManager
    let keyBindingService: KeyBindingService
    let blameService: GitBlameService
    let importResolver: ImportResolver
    let sfccService: SFCCService
    let fileWatchService: FileWatchService

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
    var sfccConnections: [SFCCConnection] = []
    var sfccAvailableLogs: [String] = []
    var sfccSelectedLog: String = ""
    var sfccLogContent: String = ""
    var sfccLogOffset: Int = 0
    @ObservationIgnored private var sfccLogTask: Task<Void, Never>?

    // MARK: - Drizzle + AI Completion
    let drizzleService: DrizzleCompletionService = DrizzleCompletionService()
    var claudeAPIKey: String = ""
    var ghostTextProvider: GhostTextProvider = .none
    var ollamaEndpoint:    String = "http://localhost:11434"
    var ollamaModel:       String = "qwen2.5-coder:7b"

    // MARK: - NPM Scripts
    var npmPackages: [NPMPackageInfo] = []
    var scriptOutput: String = ""
    var runningScriptKeys: Set<String> = []
    @ObservationIgnored private var runningScriptProcesses: [String: Process] = [:]
    let npmScriptService: NPMScriptService = NPMScriptService()

    // Selected package + script for the Scripts bottom panel.
    var selectedNPMPackageId:   String? = nil
    var selectedNPMScriptName:  String? = nil

    var selectedNPMPackage: NPMPackageInfo? {
        guard let id = selectedNPMPackageId else { return npmPackages.first }
        return npmPackages.first { $0.id == id } ?? npmPackages.first
    }

    var selectedScriptIsRunning: Bool {
        guard let pkg  = selectedNPMPackage,
              let name = selectedNPMScriptName else { return false }
        return runningScriptKeys.contains(pkg.id + ":" + name)
    }

    // MARK: - Debugger
    var debugState: DebugState = .idle
    var debugBreakpoints: [String: Set<Int>] = [:]   // filePath → line numbers
    var debugStackFrames: [DebugStackFrame] = []
    var debugVariables: [DebugVariable] = []
    var debugCurrentFile: URL? = nil
    var debugCurrentLine: Int? = nil
    var debugOutput: String = ""
    var launchConfigs: [LaunchConfig] = []
    var selectedLaunchConfigId: UUID? = nil
    @ObservationIgnored let debugService: DebugService = DebugService()

    var activeClaudeAccount: ClaudeAccount = .personal
    var claudeMessages: [ClaudeMessage] = []
    var claudeIsStreaming: Bool = false
    var showClaudePanel: Bool = false
    var claudePanelWidth: CGFloat = 340
    var keyBindings: [KeyBinding] = KeyBinding.vscodeDefaults
    var showQuickOpen: Bool = false
    /// Seeds QuickOpenView's query on presentation — "" for plain file quick-open,
    /// ">" to land directly in command-palette mode (⇧⌘P).
    var quickOpenPrefill: String = ""

    // Blame data keyed by file path.
    var blameCache: [String: [Int: BlameLine]] = [:]

    // MARK: - Editor settings (mirrored from SettingsService on launch)
    var editorFontSize:          CGFloat = 14

    /// Scale factor for all UI chrome fonts (sidebar, tabs, panels…).
    /// Derived from editorFontSize so Cmd+= / Cmd+- zooms the whole window.
    var uiScale: CGFloat { editorFontSize / 14.0 }

    /// Returns `base` multiplied by the current UI zoom scale.
    func sf(_ base: CGFloat) -> CGFloat { base * uiScale }
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
    @ObservationIgnored private var autoSaveTask:    Task<Void, Never>? = nil
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>? = nil
    @ObservationIgnored private var fileWatchTask:   Task<Void, Never>? = nil
    @ObservationIgnored private var fileTreeRebuildTask: Task<Void, Never>? = nil

    init(
        fileService: FileService = FileService(),
        gitService: GitService = GitService(),
        claudeService: ClaudeService = ClaudeService(),
        claudeCLIService: ClaudeCLIService = ClaudeCLIService(),
        searchService: SearchService = SearchService(),
        settingsService: SettingsService = SettingsService(),
        keychainService: KeychainService = KeychainService(),
        lspManager: LSPManager = LSPManager(),
        keyBindingService: KeyBindingService = KeyBindingService(),
        blameService: GitBlameService = GitBlameService(),
        importResolver: ImportResolver = ImportResolver(),
        sfccService: SFCCService = SFCCService(),
        fileWatchService: FileWatchService = FileWatchService()
    ) {
        self.fileService = fileService
        self.gitService = gitService
        self.claudeService = claudeService
        self.claudeCLIService = claudeCLIService
        self.searchService = searchService
        self.settingsService = settingsService
        self.keychainService = keychainService
        self.lspManager = lspManager
        self.keyBindingService = keyBindingService
        self.blameService = blameService
        self.importResolver = importResolver
        self.sfccService = sfccService
        self.fileWatchService = fileWatchService
    }

    // MARK: - Methods

    /// Opens a file URL in a new tab, or activates the existing tab if already open.
    func openFile(_ url: URL) async {
        // If the file is already open, just activate it.
        if let existing = openTabs.first(where: { $0.fileURL == url }) {
            activeTabId = existing.id
            await persistSession()
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
            AppState.registerRecentPath(url)
            await fileWatchService.watchFile(url)
            await persistSession()

            // Bring up the language server (no-op if none is installed) and tell
            // it about the newly opened document. Fired unstructured so file
            // opening itself stays instant.
            if let workspace {
                let language = tab.language
                Task {
                    try? await self.lspManager.startServer(for: language, workspaceURL: workspace.rootURL)
                    await self.lspManager.didOpen(fileURL: url, content: content)
                }
            }
        } catch {
            statusMessage = "Error opening \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Resolves `importPath` relative to `currentFileURL` and opens the result.
    func openImportedFile(_ importPath: String, from currentFileURL: URL) async {
        if let resolved = await importResolver.resolve(
            importPath,
            from: currentFileURL,
            workspaceURL: workspace?.rootURL
        ) {
            await openFile(resolved)
        } else {
            statusMessage = "Cannot resolve import: \(importPath)"
        }
    }

    /// Closes the tab with the given ID, activating an adjacent tab if needed.
    func closeTab(_ id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }

        if let url = openTabs[index].fileURL {
            Task {
                await self.lspManager.didClose(fileURL: url)
                await self.fileWatchService.stopWatchingFile(url)
            }
            diagnostics.removeValue(forKey: url)
        }

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

        // Persist the updated tab layout so a relaunch reopens what's still open.
        Task { await self.persistSession() }
    }

    /// Activates the tab with the given ID (e.g. a tab-bar click) and persists
    /// the new selection so a relaunch restores the same active tab.
    func activateTab(_ id: UUID) {
        activeTabId = id
        Task { await self.persistSession() }
    }

    /// Opens a workspace directory, builds the file tree, and refreshes Git status.
    func openWorkspace(_ url: URL) async {
        // Tear down any language servers (and their diagnostics) left over from
        // a previously open workspace before switching roots. This must be
        // awaited before any file in the new workspace can be opened, otherwise
        // LSPManager.startServer(for:workspaceURL:) — which only checks whether a
        // server for the language already exists — would find the stale server
        // still registered and skip starting a correctly-rooted one.
        await lspManager.stopAllServers()
        diagnostics = [:]

        workspace = WorkspaceModel(rootURL: url)
        statusMessage = "Opening workspace \(url.lastPathComponent)…"

        do {
            fileTree = try await fileService.buildFileTree(url)
        } catch {
            statusMessage = "Error building file tree: \(error.localizedDescription)"
        }

        // Replaces any watch left over from a previously open workspace root.
        await fileWatchService.watchDirectory(url)

        await refreshGitStatus()
        statusMessage = url.lastPathComponent

        try? await settingsService.setValue(url.path, for: "lastWorkspacePath")
        AppState.registerRecentPath(url)

        await discoverNPMPackages()
        await restoreSession(for: url)
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

        // Ghost text / predictive completion provider
        async let gtp = settingsService.value(for: "ghostTextProvider", default: "none")
        async let oep = settingsService.value(for: "ollamaEndpoint",    default: "http://localhost:11434")
        async let om  = settingsService.value(for: "ollamaModel",       default: "qwen2.5-coder:7b")
        ghostTextProvider = GhostTextProvider(rawValue: await gtp) ?? .none
        ollamaEndpoint    = await oep
        ollamaModel       = await om

        // Claude API key (shared with chat) — stored in the Keychain
        await loadClaudeAPIKey()
    }

    /// Persists a single setting value, ignoring errors.
    func persistSetting<T: Codable & Sendable>(_ value: T, for key: String) {
        Task { try? await settingsService.setValue(value, for: key) }
    }

    // MARK: - Claude API key (Keychain-backed)

    /// Loads the API key from the Keychain, migrating any legacy plaintext key
    /// that an older build persisted in the settings JSON.
    func loadClaudeAPIKey() async {
        if let key = await keychainService.get(account: KeychainService.claudeAPIKeyAccount), !key.isEmpty {
            claudeAPIKey = key
            return
        }
        let legacy = await settingsService.claudeApiKey()
        if !legacy.isEmpty {
            try? await keychainService.set(legacy, account: KeychainService.claudeAPIKeyAccount)
            await settingsService.reset(key: "claudeApiKey")
        }
        claudeAPIKey = legacy
    }

    /// Updates the in-memory key and persists it to the Keychain.
    func setClaudeAPIKey(_ key: String) {
        claudeAPIKey = key
        Task { try? await keychainService.set(key, account: KeychainService.claudeAPIKeyAccount) }
    }

    // MARK: - AI Ghost Text

    /// Calls claude-haiku for a short inline code completion at the cursor.
    /// Returns `nil` when no API key is configured or the request fails.
    func requestInlineCompletion(prefix: String, suffix: String) async -> String? {
        switch ghostTextProvider {
        case .none:   return nil
        case .claude: return await requestClaudeInlineCompletion(prefix: prefix, suffix: suffix)
        case .ollama: return await requestOllamaInlineCompletion(prefix: prefix, suffix: suffix)
        }
    }

    private func requestClaudeInlineCompletion(prefix: String, suffix: String) async -> String? {
        guard !claudeAPIKey.isEmpty else { return nil }

        let context = String(prefix.suffix(600)) + "<CURSOR>" + String(suffix.prefix(200))
        let body: [String: Any] = [
            "model":      "claude-haiku-4-5-20251001",
            "max_tokens": 80,
            "system":     "You are a code completion engine. Output ONLY the text that should appear at <CURSOR>. No explanation, no markdown, no backticks. Complete at most one line.",
            "messages":   [["role": "user", "content": context]],
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(claudeAPIKey,        forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 10
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        guard
            let (respData, _) = try? await URLSession.shared.data(for: req),
            let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String,
            !text.isEmpty
        else { return nil }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestOllamaInlineCompletion(prefix: String, suffix: String) async -> String? {
        let base = ollamaEndpoint.hasSuffix("/") ? String(ollamaEndpoint.dropLast()) : ollamaEndpoint
        // Use the native generate endpoint with fill-in-middle: it returns ONLY the
        // continuation rather than echoing the prompt back (which chat models do).
        guard let url = URL(string: "\(base)/api/generate") else { return nil }

        // qwen3-coder and similar instruct models reject FIM "suffix" ("does not
        // support insert"), so we send prompt-only and strip the echoed prefix below.
        let promptHead = String(prefix.suffix(2000))
        let body: [String: Any] = [
            "model":  ollamaModel,
            "prompt": promptHead,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": 96,
            ],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        let respData: Data
        let response: URLResponse
        do {
            (respData, response) = try await URLSession.shared.data(for: req)
        } catch {
            statusMessage = "Ollama unreachable at \(base): \(error.localizedDescription)"
            return nil
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: respData, encoding: .utf8)?.prefix(200) ?? ""
            statusMessage = "Ollama error \(http.statusCode) (model \(ollamaModel)): \(detail)"
            return nil
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
            let text = json["response"] as? String
        else { return nil }

        return Self.cleanInlineCompletion(text, prefix: promptHead)
    }

    /// Strips markdown fences and any echoed prefix from a raw model completion,
    /// returning `nil` when nothing usable remains. Instruct models like
    /// qwen3-coder reproduce the prompt before continuing it, so we cut the
    /// longest suffix of `prefix` that the response repeats at its head.
    private static func cleanInlineCompletion(_ raw: String, prefix: String) -> String? {
        var text = raw

        // Drop a leading ```lang fence and any trailing ``` fence.
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```") {
                text = String(text[..<fence.lowerBound])
            }
        }
        text = text.trimmingCharacters(in: .newlines)

        // Remove echoed prompt: find the longest suffix of `prefix` (up to 400
        // chars) that the response repeats at its start, and drop it.
        let maxOverlap = min(prefix.count, text.count, 400)
        if maxOverlap > 0 {
            for len in stride(from: maxOverlap, through: 1, by: -1) {
                if text.hasPrefix(String(prefix.suffix(len))) {
                    text = String(text.dropFirst(len))
                    break
                }
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Session Restore

    /// Reopens the last workspace if one was saved; called on app launch.
    func restoreLastWorkspace() async {
        let path = await settingsService.value(for: "lastWorkspacePath", default: "")
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        await openWorkspace(url)
    }

    /// Reopens every tab persisted for `workspaceURL`'s previous session (in
    /// order, skipping any file that no longer exists on disk so a routine
    /// deleted/moved file doesn't crash or surface a confusing error),
    /// restores the previously-active tab, and restores each tab's last
    /// cursor line/column. Called from `openWorkspace(_:)` right after the
    /// file tree is built, so both explicit "Open Folder" and the launch-time
    /// `restoreLastWorkspace()` path get their tabs back.
    private func restoreSession(for workspaceURL: URL) async {
        let sessions: [String: WorkspaceSession] = await settingsService.value(for: "workspaceSessions", default: [:])
        guard let session = sessions[workspaceURL.path], !session.tabs.isEmpty else { return }

        for persisted in session.tabs {
            guard FileManager.default.fileExists(atPath: persisted.path) else { continue }
            let fileURL = URL(fileURLWithPath: persisted.path)
            await openFile(fileURL)
            if let idx = openTabs.firstIndex(where: { $0.fileURL == fileURL }) {
                openTabs[idx].cursorLine   = persisted.cursorLine
                openTabs[idx].cursorColumn = persisted.cursorColumn
            }
        }

        if let activePath = session.activePath,
           let tab = openTabs.first(where: { $0.fileURL?.path == activePath }) {
            activeTabId = tab.id
        }

        // Re-save immediately so a since-deleted file silently drops out of
        // the session instead of being retried (and skipped) on every future
        // launch or reopen of this same folder.
        await persistSession()
    }

    /// Persists the current tab layout (open files + active tab + per-tab
    /// cursor position) for the current workspace, keyed by its root path in
    /// the `"workspaceSessions"` settings entry, so `restoreSession(for:)` can
    /// rebuild it next time this folder is opened. Untitled (unsaved) tabs
    /// have no `fileURL` and are intentionally not persisted.
    private func persistSession() async {
        guard let ws = workspace else { return }
        var sessions: [String: WorkspaceSession] = await settingsService.value(for: "workspaceSessions", default: [:])
        let tabs = openTabs.compactMap { tab -> SessionTab? in
            guard let url = tab.fileURL else { return nil }
            return SessionTab(path: url.path, cursorLine: tab.cursorLine, cursorColumn: tab.cursorColumn)
        }
        let activePath = openTabs.first(where: { $0.id == activeTabId })?.fileURL?.path
        sessions[ws.rootURL.path] = WorkspaceSession(tabs: tabs, activePath: activePath)
        try? await settingsService.setValue(sessions, for: "workspaceSessions")
    }

    /// Saves the content of the currently active tab to disk.
    func saveActiveTab() async {
        guard
            var tab = activeTab,
            let url = tab.fileURL
        else { return }

        do {
            try await fileService.writeFile(url, content: tab.content)
            if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
                openTabs[index].isDirty = false
                // A completed save overwrites whatever triggered the
                // "changed on disk" banner, so it's no longer relevant.
                openTabs[index].externallyModified = false
                tab = openTabs[index]
            }
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            statusMessage = "Error saving \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }

        // Upload to active SFCC sandbox if one is configured.
        if let conn = sfccConnections.first(where: { $0.isActive }),
           let ws = workspace {
            let savedURL = url
            let workspaceURL = ws.rootURL
            Task {
                do {
                    let msg = try await sfccService.upload(
                        fileURL: savedURL, connection: conn, workspaceURL: workspaceURL
                    )
                    statusMessage = msg
                } catch SFCCError.notInCartridge {
                    // File is outside cartridges root — silently skip
                } catch {
                    statusMessage = "SFCC: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Save As / Revert / Close Folder

    func saveActiveTabAs() async {
        guard let tab = activeTab else { return }
        let panel = NSSavePanel()
        panel.title = "Save As"
        if let url = tab.fileURL {
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        } else {
            panel.nameFieldStringValue = "Untitled"
        }
        let response = await withCheckedContinuation { cont in
            panel.begin { cont.resume(returning: $0) }
        }
        guard response == .OK, let newURL = panel.url else { return }
        do {
            try await fileService.writeFile(newURL, content: tab.content)
            if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
                openTabs[index].fileURL    = newURL
                openTabs[index].title      = newURL.lastPathComponent
                openTabs[index].isDirty    = false
                openTabs[index].externallyModified = false
                openTabs[index].language   = Language.detect(from: newURL)
            }
            statusMessage = "Saved \(newURL.lastPathComponent)"
            AppState.registerRecentPath(newURL)
            if let previousURL = tab.fileURL {
                await fileWatchService.stopWatchingFile(previousURL)
            }
            await fileWatchService.watchFile(newURL)
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func revertActiveTab() async {
        guard let tab = activeTab, let url = tab.fileURL else { return }
        do {
            let content = try await fileService.readFile(url)
            if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
                openTabs[index].content = content
                openTabs[index].isDirty = false
                openTabs[index].externallyModified = false
            }
            statusMessage = "Reverted \(url.lastPathComponent)"
        } catch {
            statusMessage = "Revert failed: \(error.localizedDescription)"
        }
    }

    func closeFolder() async {
        // Must be awaited before any new workspace/file can be opened — see the
        // comment in openWorkspace(_:) for why an unawaited Task here would let a
        // stale, wrong-rootUri server keep serving the next-opened workspace.
        await lspManager.stopAllServers()
        await fileWatchService.stopAll()
        diagnostics  = [:]

        workspace    = nil
        fileTree     = []
        gitStatus    = GitStatus()
        openTabs     = []
        activeTabId  = nil
        statusMessage = ""
    }

    /// Registers `url` at the top of the recent-paths list (max 15 entries).
    static func registerRecentPath(_ url: URL) {
        let key   = "athenaRecentPaths"
        var paths = (UserDefaults.standard.string(forKey: key) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let path  = url.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(15)).joined(separator: "\n"), forKey: key)
    }

    // MARK: - NPM Scripts

    func discoverNPMPackages() async {
        guard let ws = workspace else { npmPackages = []; return }
        npmPackages = await npmScriptService.discoverPackages(in: ws.rootURL)
        // Auto-select the first package if nothing is selected (or if previous selection is gone).
        if selectedNPMPackageId == nil || !npmPackages.contains(where: { $0.id == selectedNPMPackageId }) {
            selectedNPMPackageId = npmPackages.first?.id
        }
    }

    func runNPMScript(_ script: String, in package: NPMPackageInfo) {
        let dir = package.path.deletingLastPathComponent()
        let key = package.id + ":" + script
        let pm  = package.packageManager.rawValue

        showBottomPanel = true
        // Stay in Scripts panel if already there; otherwise open Output.
        if activeBottomPanel != .scripts { activeBottomPanel = .output }
        scriptOutput += "\n$ \(pm) run \(script)\n"

        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "\(pm) run \(script)"]
        process.currentDirectoryURL = dir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.scriptOutput += text
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.scriptOutput += "\n[Process exited with code \(proc.terminationStatus)]\n"
                self?.runningScriptKeys.remove(key)
                self?.runningScriptProcesses.removeValue(forKey: key)
            }
        }

        do {
            try process.run()
            runningScriptProcesses[key] = process
            runningScriptKeys.insert(key)
        } catch {
            scriptOutput += "Error: \(error.localizedDescription)\n"
        }
    }

    func stopNPMScript(key: String) {
        runningScriptProcesses[key]?.terminate()
    }

    // MARK: - Debugger

    func toggleBreakpoint(filePath: String, line: Int) {
        if debugBreakpoints[filePath] == nil {
            debugBreakpoints[filePath] = []
        }
        if debugBreakpoints[filePath]!.contains(line) {
            debugBreakpoints[filePath]!.remove(line)
        } else {
            debugBreakpoints[filePath]!.insert(line)
        }
    }

    func startDebugging() async {
        guard debugState == .idle || debugState == .stopped,
              let config = launchConfigs.first(where: { $0.id == selectedLaunchConfigId })
               ?? launchConfigs.first
        else { return }

        debugState = .launching
        debugOutput = ""
        debugStackFrames = []
        debugVariables = []
        debugCurrentFile = nil
        debugCurrentLine = nil
        showBottomPanel = true
        activeBottomPanel = .output

        // Wire up callbacks before launching.
        await debugService.setCallbacks(
            onStateChange: { [weak self] state in self?.debugState = state },
            onOutput:      { [weak self] text  in self?.debugOutput += text },
            onStopped:     { [weak self] stop  in
                guard let self else { return }
                if let path = stop.filePath {
                    self.debugCurrentFile = URL(fileURLWithPath: path)
                    self.debugCurrentLine = stop.line
                    Task { await self.refreshDebugState() }
                }
            }
        )

        let bpMap = debugBreakpoints.mapValues { Array($0) }

        do {
            try await debugService.launch(config, workspaceURL: workspace?.rootURL, breakpointsByFile: bpMap)
            debugOutput += "[Athena] Debug session started: \(config.name)\n"
        } catch {
            debugOutput += "[Athena] Failed to start debugger: \(error.localizedDescription)\n"
            debugState = .stopped
        }
    }

    func stopDebugging() async {
        await debugService.disconnect()
        debugCurrentFile = nil
        debugCurrentLine = nil
        debugStackFrames = []
        debugVariables   = []
    }

    func debugContinue() async {
        try? await debugService.continueExecution()
        debugCurrentLine = nil
    }

    func debugStepOver() async {
        try? await debugService.stepOver()
    }

    func debugStepIn() async {
        try? await debugService.stepIn()
    }

    func debugStepOut() async {
        try? await debugService.stepOut()
    }

    func debugPause() async {
        try? await debugService.pause()
    }

    private func refreshDebugState() async {
        guard case .paused = debugState else { return }
        do {
            debugStackFrames = try await debugService.fetchStackFrames()
            if let topFrame = debugStackFrames.first {
                debugVariables = try await debugService.fetchVariables(frameId: topFrame.id)
            }
            // Navigate to the paused file if it's different from the active tab.
            if let file = debugCurrentFile {
                await openFile(file)
            }
        } catch {
            debugOutput += "[Athena] Error fetching debug state: \(error.localizedDescription)\n"
        }
    }

    func loadLaunchConfigs() {
        guard let ws = workspace else { launchConfigs = builtInLaunchConfigs(); return }
        let launchJSON = ws.rootURL
            .appendingPathComponent(".vscode")
            .appendingPathComponent("launch.json")

        if let data = try? Data(contentsOf: launchJSON),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let configs = json["configurations"] as? [[String: Any]] {
            launchConfigs = configs.compactMap { c -> LaunchConfig? in
                guard let type = c["type"] as? String,
                      let name = c["name"] as? String,
                      let req  = c["request"] as? String else { return nil }
                return LaunchConfig(
                    type:         type,
                    request:      req,
                    name:         name,
                    program:      c["program"] as? String ?? "",
                    args:         c["args"]    as? [String]         ?? [],
                    env:          c["env"]     as? [String: String] ?? [:],
                    cwd:          c["cwd"]     as? String ?? "${workspaceFolder}",
                    stopOnEntry:  c["stopOnEntry"] as? Bool ?? false,
                    debugPort:    c["port"] as? Int ?? c["debugPort"] as? Int,
                    url:          c["url"] as? String
                )
            }
        } else {
            launchConfigs = builtInLaunchConfigs()
        }

        if selectedLaunchConfigId == nil || !launchConfigs.contains(where: { $0.id == selectedLaunchConfigId }) {
            selectedLaunchConfigId = launchConfigs.first?.id
        }
    }

    private func builtInLaunchConfigs() -> [LaunchConfig] {
        var configs: [LaunchConfig] = []

        // Language-specific configs for the active tab.
        if let tab = activeTab {
            switch tab.language {
            case .swift:
                configs.append(LaunchConfig(
                    type: "lldb", request: "launch", name: "Debug Swift",
                    program: "${workspaceFolder}/.build/debug/\(workspace?.name ?? "App")"))
            case .python:
                configs.append(LaunchConfig(
                    type: "python", request: "launch", name: "Debug Python",
                    program: "${file}"))
            default:
                break
            }
        }

        // Node.js and browser configs are always included (no external adapter required).
        configs += [
            LaunchConfig(type: "node-cdp", request: "launch",
                         name: "Debug Node.js (current file)",
                         program: "${file}", debugPort: 9229),
            LaunchConfig(type: "node-cdp", request: "attach",
                         name: "Attach to Node.js (port 9229)",
                         program: "", debugPort: 9229),
            LaunchConfig(type: "chrome", request: "launch",
                         name: "Debug in Chrome",
                         program: "", debugPort: 9222, url: "http://localhost:3000"),
            LaunchConfig(type: "nextjs", request: "launch",
                         name: "Debug Next.js (browser)",
                         program: "", debugPort: 9222, url: "http://localhost:3000"),
        ]
        return configs
    }

    // MARK: - SFCC log viewer

    func refreshSFCCLogs(for connection: SFCCConnection) async {
        do {
            let logs = try await sfccService.listLogs(connection: connection)
            sfccAvailableLogs = logs.sorted()
            if !logs.isEmpty && (sfccSelectedLog.isEmpty || !logs.contains(sfccSelectedLog)) {
                sfccSelectedLog = logs.first(where: { $0.contains("customerror") })
                    ?? logs.first(where: { $0.contains("error") })
                    ?? logs[0]
                sfccLogContent = ""
                sfccLogOffset = 0
            }
        } catch {
            statusMessage = "SFCC logs: \(error.localizedDescription)"
        }
    }

    func startSFCCLogPolling() async {
        guard let conn = sfccConnections.first(where: { $0.isActive }) else { return }
        if sfccAvailableLogs.isEmpty { await refreshSFCCLogs(for: conn) }
        sfccLogTask?.cancel()
        sfccLogTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollLogOnce()
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 s
            }
        }
    }

    func stopSFCCLogPolling() {
        sfccLogTask?.cancel()
        sfccLogTask = nil
    }

    private func pollLogOnce() async {
        guard let conn = sfccConnections.first(where: { $0.isActive }),
              !sfccSelectedLog.isEmpty else { return }
        do {
            let (text, next) = try await sfccService.fetchLogTail(
                logName: sfccSelectedLog, connection: conn, fromByte: sfccLogOffset
            )
            if !text.isEmpty {
                sfccLogContent += text
                sfccLogOffset = next
            }
        } catch { }   // swallow poll errors silently
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

    /// Discards unstaged working-tree changes to `path` (relative to the
    /// workspace root), reverting it to its last-committed contents, then
    /// refreshes Git status. Destructive and irreversible — callers must
    /// confirm with the user first.
    ///
    /// If the file is currently open in a tab, its buffer is reloaded from
    /// disk directly (not via `updateTabContent`, which would mark the tab
    /// dirty again and fire an unwanted LSP `didChange`).
    func discardChanges(path: String) async {
        guard let workspace else { return }
        let url = workspace.rootURL.appendingPathComponent(path)

        do {
            try await gitService.restore([path], at: workspace.rootURL)
        } catch {
            statusMessage = "Discard failed: \(error.localizedDescription)"
            return
        }

        await refreshGitStatus()

        if let index = openTabs.firstIndex(where: { $0.fileURL == url }),
           let content = try? await fileService.readFile(url)
        {
            openTabs[index].content = content
            openTabs[index].isDirty = false
            openTabs[index].externallyModified = false
        }
    }

    /// Updates the text content of a tab and marks it as dirty.
    func updateTabContent(_ id: UUID, content: String) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        openTabs[index].content = content
        openTabs[index].isDirty = true

        if let url = openTabs[index].fileURL {
            Task { await self.lspManager.didChange(fileURL: url, content: content) }
        }

        // Auto-save: debounce 1 s after the last keystroke.
        if UserDefaults.standard.bool(forKey: "athenaAutoSave") {
            autoSaveTask?.cancel()
            autoSaveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.saveActiveTab()
            }
        }
    }

    // MARK: - Workspace Search & Replace

    /// Replaces every match of `query` with `replacement` across every file
    /// `SearchService` currently reports a hit for, writing each change to
    /// disk via `fileService.writeFile` (not ripgrep's own `--replace`, so
    /// results stay consistent with how the rest of the app writes files).
    ///
    /// Re-runs the search itself (rather than trusting the possibly-stale
    /// `searchResults` the panel already has) so this always acts on the
    /// current contents of the workspace. Any open tab for a touched file is
    /// reloaded directly (the same bypass-`updateTabContent` pattern
    /// `discardChanges` uses) and marked **not** dirty, since the write
    /// already landed on disk. Returns the total occurrences replaced and
    /// the number of files touched, for a status-bar summary — bulk replace
    /// across a workspace is destructive enough to warrant visible feedback.
    func replaceAllInWorkspace(
        query: String,
        replacement: String,
        regex: Bool,
        caseSensitive: Bool,
        wholeWord: Bool,
        filter: SearchFilter = SearchFilter()
    ) async -> (occurrences: Int, files: Int) {
        guard let workspace, !query.isEmpty else { return (0, 0) }
        guard let matcher = TextSearchMatcher(
            query: query, isRegex: regex, caseSensitive: caseSensitive, wholeWord: wholeWord
        ) else {
            statusMessage = "Invalid regular expression"
            return (0, 0)
        }

        var filePaths: [String] = []
        var seen = Set<String>()
        await searchService.cancel()
        let stream = await searchService.search(
            query: query, in: workspace.rootURL,
            regex: regex, caseSensitive: caseSensitive, filter: filter
        )
        for await result in stream where seen.insert(result.filePath).inserted {
            filePaths.append(result.filePath)
        }

        var totalOccurrences = 0
        var filesChanged = 0

        for path in filePaths {
            let url = URL(fileURLWithPath: path)
            guard let original = try? await fileService.readFile(url) else { continue }
            let (replaced, count) = matcher.replacingAll(in: original, with: replacement)
            guard count > 0 else { continue }

            do {
                try await fileService.writeFile(url, content: replaced)
            } catch {
                continue
            }

            totalOccurrences += count
            filesChanged += 1

            if let index = openTabs.firstIndex(where: { $0.fileURL == url }) {
                openTabs[index].content = replaced
                openTabs[index].isDirty = false
                openTabs[index].externallyModified = false
            }
        }

        statusMessage = filesChanged == 0
            ? "No occurrences of \"\(query)\" found"
            : "Replaced \(totalOccurrences) occurrence\(totalOccurrences == 1 ? "" : "s") across \(filesChanged) file\(filesChanged == 1 ? "" : "s")"

        return (totalOccurrences, filesChanged)
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

    // MARK: - LSP

    /// Starts consuming `LSPManager`'s diagnostics stream, populating
    /// `diagnostics` as running servers publish them. Idempotent — call once
    /// at app launch. The Task is created from this MainActor-isolated method
    /// so it inherits MainActor isolation, matching `autoSaveTask`/`sfccLogTask`.
    func startDiagnosticsConsumer() {
        guard diagnosticsTask == nil else { return }
        diagnosticsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.lspManager.diagnosticsStream()
            for await (url, diags) in stream {
                self.diagnostics[url] = diags
            }
        }
    }

    // MARK: - File Watching

    /// Subscribes to `FileWatchService.eventStream()` for the app's lifetime.
    /// Call once at launch, mirroring `startDiagnosticsConsumer()`.
    func startFileWatchConsumer() {
        guard fileWatchTask == nil else { return }
        fileWatchTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.fileWatchService.eventStream()
            for await event in stream {
                await self.handleFileWatchEvent(event)
            }
        }
    }

    private func handleFileWatchEvent(_ event: FileWatchEvent) async {
        switch event {
        case .directoryChanged:
            scheduleFileTreeRebuild()
        case .fileChanged(let url):
            await handleExternalFileChange(url)
        case .fileDeleted(let url):
            await handleExternalFileRemoval(url)
        }
    }

    /// Debounces workspace-root directory events ~300ms before rebuilding the
    /// file tree, so a burst of changes (e.g. `git pull`, `npm install`)
    /// triggers one rebuild instead of one per touched file.
    private func scheduleFileTreeRebuild() {
        fileTreeRebuildTask?.cancel()
        fileTreeRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshFileTree()
        }
    }

    private func refreshFileTree() async {
        guard let workspace else { return }
        do {
            fileTree = try await fileService.buildFileTree(workspace.rootURL)
        } catch {
            statusMessage = "Error refreshing file tree: \(error.localizedDescription)"
        }
    }

    /// An open tab's backing file changed on disk. If the tab has no unsaved
    /// edits, reload it silently (bypassing `updateTabContent` so this
    /// doesn't re-mark the tab dirty or re-fire LSP `didChange` — same
    /// reasoning as the reload in `discardChanges(path:)`). If the tab has
    /// unsaved edits, don't clobber them — flag the tab so the editor can
    /// show a "file changed on disk" banner instead.
    private func handleExternalFileChange(_ url: URL) async {
        guard let index = openTabs.firstIndex(where: { $0.fileURL == url }) else { return }

        if openTabs[index].isDirty {
            openTabs[index].externallyModified = true
            return
        }

        guard let content = try? await fileService.readFile(url) else { return }
        openTabs[index].content = content
        openTabs[index].isDirty = false
        openTabs[index].externallyModified = false
    }

    /// `FileWatchService` reports "gone" whenever the descriptor it was
    /// watching stops resolving at `url` — which is ambiguous by itself: a
    /// genuine delete looks identical to an atomic-save tool (`git checkout`,
    /// many editors) that writes a temp file and renames it over the
    /// original for durability. Disambiguate by checking whether the path
    /// still exists: if it does, this was a rename-over — re-arm the watch
    /// (the service already tore down the stale one) and treat it as an
    /// ordinary content change; if it doesn't, the file is genuinely gone.
    private func handleExternalFileRemoval(_ url: URL) async {
        guard openTabs.contains(where: { $0.fileURL == url }) else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            await fileWatchService.watchFile(url)
            await handleExternalFileChange(url)
        } else {
            markFileOrphaned(url)
        }
    }

    /// A truly-deleted file's tab: force it dirty rather than let a later
    /// save silently fail — the status bar message is the signal for this
    /// pass; the banner is reserved for the "changed while dirty" case above.
    private func markFileOrphaned(_ url: URL) {
        guard let index = openTabs.firstIndex(where: { $0.fileURL == url }) else { return }
        openTabs[index].isDirty = true
        statusMessage = "\(url.lastPathComponent) was deleted on disk — save to recreate it."
    }

    /// "Reload" banner action: discards local edits and reloads the tab's
    /// content from disk.
    func reloadTabFromDisk(_ id: UUID) async {
        guard
            let index = openTabs.firstIndex(where: { $0.id == id }),
            let url = openTabs[index].fileURL,
            let content = try? await fileService.readFile(url)
        else { return }
        openTabs[index].content = content
        openTabs[index].isDirty = false
        openTabs[index].externallyModified = false
    }

    /// "Keep My Changes" banner action: dismisses the notice without
    /// touching the buffer — the next save overwrites the on-disk version.
    func keepLocalChanges(_ id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        openTabs[index].externallyModified = false
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
        guard let combo = KeyCombo.from(keyCode: keyCode, modRaw: modRaw, chars: chars) else { return false }

        // Zoom shortcuts accept both Cmd+= and Cmd++ (Shift+=), and Cmd+- and Cmd+_ (Shift+-).
        // Try the base-key (no-shift) variant so either key press fires the registered binding.
        let comboNoShift = KeyCombo(key: combo.key, command: combo.command,
                                    shift: false, option: combo.option, control: combo.control)
        let lookup = combo.shift ? (keyBindings.first(where: { $0.combo == combo })
                                 ?? keyBindings.first(where: { $0.combo == comboNoShift }))
                                 : keyBindings.first(where: { $0.combo == combo })

        guard let binding = lookup else { return false }
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
        case .commandPalette:
            presentQuickOpen(prefill: ">")
        case .nextTab:
            cycleTab(forward: true)
        case .previousTab:
            cycleTab(forward: false)
        // Editor-level actions are forwarded to the active text view, which
        // owns the selection and undo stack.
        case .findInFile:
            postEditorCommand(.find)
        case .findAndReplace:
            postEditorCommand(.findAndReplace)
        case .goToLine:
            postEditorCommand(.goToLine)
        case .toggleComment:
            postEditorCommand(.toggleComment)
        case .indentLine:
            postEditorCommand(.indent)
        case .outdentLine:
            postEditorCommand(.outdent)
        case .selectNextOccurrence:
            postEditorCommand(.selectNextOccurrence)
        case .zoomIn:
            adjustFontSize(by: 2)
        case .zoomOut:
            adjustFontSize(by: -2)
        case .resetZoom:
            resetFontSize()
        }
    }

    /// Forwards an editor command to the active EditorView's coordinator.
    private func postEditorCommand(_ command: EditorCommand) {
        NotificationCenter.default.post(name: .athenaEditorCommand, object: command)
    }

    private func presentQuickOpen(prefill: String = "") {
        quickOpenPrefill = prefill
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
                    openTabs[i].externallyModified = false
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
        Task { await self.persistSession() }
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
        Task { await self.persistSession() }
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
