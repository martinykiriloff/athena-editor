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
    let prettierService: PrettierService

    // MARK: - UI State

    var workspace: WorkspaceModel?
    var openTabs: [TabModel] = []
    var activeTabId: UUID?

    // MARK: - Editor Groups (Split Editor)

    /// The secondary editor pane's tab state (plan.md item 22, "Split
    /// Editor Right"). `nil` means single-pane — `openTabs`/`activeTabId`
    /// above ARE the primary group's state (see `EditorGroupSide`'s doc
    /// comment in SharedTypes.swift). Created by `splitEditorRight()`;
    /// closing its last tab sets this back to `nil` (collapses to
    /// single-pane).
    var secondaryGroup: EditorGroup?
    /// Which pane the user last interacted with (activated a tab in it, or
    /// clicked/moved the cursor in its editor — see `activateTab(_:)` and
    /// `setCursorPosition`). Determines which group "current file" commands
    /// (Cmd+S, Save As, Revert, format-on-save, breadcrumbs, Go to
    /// Symbol/Outline) act on via `focusedTab`. Always `.primary` while
    /// `secondaryGroup == nil`, so single-pane behavior is unaffected.
    var focusedGroup: EditorGroupSide = .primary

    var fileTree: [FileNode] = []
    var gitStatus: GitStatus = GitStatus()
    /// All local + remote-tracking branches for the current workspace, kept
    /// fresh opportunistically by `refreshGitStatus()`. Powers the
    /// branch-switcher menu in `StatusBarView` (plan.md item 20 point 1).
    var branches: [GitBranch] = []
    var searchResults: [SearchResult] = []
    var diagnostics: [URL: [Diagnostic]] = [:]
    var chatMessages: [ChatMessage] = []
    var isStreaming: Bool = false
    var activeSidebarPanel: SidebarPanel = .files
    var showSidebar: Bool = true
    var showBottomPanel: Bool = false
    /// Distraction-free mode (plan.md item 28, "C8") — hides the activity
    /// bar, sidebar, tab bar, and status bar, leaving just the editor
    /// content (centered with a max width, VS Code-style). Deliberately a
    /// plain bool rather than deriving from `showSidebar`/`showBottomPanel`
    /// etc.: toggling Zen mode off must restore whichever of those the user
    /// had before entering it, so their own state has to be preserved
    /// untouched underneath (`MainWindowView`/`EditorContainerView` gate on
    /// `showSidebar && !isZenMode` etc., not one flag stomping the other).
    var isZenMode: Bool = false
    var activeBottomPanel: BottomPanel = .terminal
    var sidebarWidth: CGFloat = 260
    var bottomPanelHeight: CGFloat = 220
    var statusMessage: String = ""
    var searchQuery: String = ""
    var commitMessage: String = ""
    var currentTheme: EditorTheme = .darcula
    /// User-imported VS Code themes (plan.md item 27, "G4"), persisted via
    /// `settingsService` under the `"customThemes"` key alongside every
    /// other setting. Combined with the built-ins for the theme picker via
    /// `allThemes` — kept separate from `EditorTheme.all` so built-in theme
    /// resolution (`EditorTheme.named(_:)`) stays a pure static lookup.
    var customThemes: [EditorTheme] = []
    var dbConnections: [DBConnection] = []
    var sfccConnections: [SFCCConnection] = []
    var sfccAvailableLogs: [String] = []
    var sfccSelectedLog: String = ""
    var sfccLogContent: String = ""
    var sfccLogOffset: Int = 0
    @ObservationIgnored private var sfccLogTask: Task<Void, Never>?

    // MARK: - Terminal Sessions

    /// Every open terminal tab (plan.md item 21). Defaults to a single
    /// session at launch so a user who never touches this feature sees the
    /// same single-terminal behavior as before — see `init`.
    var terminalSessions: [TerminalSession] = []
    var activeTerminalSessionId: UUID?
    /// Monotonically increasing per launch (never reused, unlike
    /// `terminalSessions.count`) so two sessions never collide on the same
    /// default title after one is closed and a new one is opened in between.
    @ObservationIgnored private var terminalSessionSequence: Int = 0

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

    /// The stack frame `DebugSidebarView`'s call-stack list has selected —
    /// `nil` until a pause happens, then defaults to the top/innermost frame
    /// (plan.md item 24). Both watch expressions and the debug console REPL
    /// evaluate against this frame, not just "the debuggee" generically.
    var selectedFrameId: Int? = nil
    /// User-defined watch expressions (plan.md item 24) — persist across
    /// debug steps and re-evaluate every time the debugger pauses.
    var watchExpressions: [WatchExpression] = []
    /// Debug console REPL transcript (plan.md item 24) — one entry per
    /// evaluated expression, shown in `DebugConsoleView`.
    var debugConsoleEntries: [DebugConsoleEntry] = []

    var activeClaudeAccount: ClaudeAccount = .personal
    var claudeMessages: [ClaudeMessage] = []
    var claudeIsStreaming: Bool = false
    var showClaudePanel: Bool = false
    var claudePanelWidth: CGFloat = 340
    var keyBindings: [KeyBinding] = KeyBinding.vscodeDefaults
    var showQuickOpen: Bool = false
    /// Seeds QuickOpenView's query on presentation — "" for plain file quick-open,
    /// ">" to land directly in command-palette mode (⇧⌘P), "@" for Go to
    /// Symbol (⇧⌘O).
    var quickOpenPrefill: String = ""

    // MARK: - Diff Viewer

    /// The Git file change currently shown in `DiffViewerView`'s overlay —
    /// `nil` when the viewer isn't presented. Set by `GitPanelView`'s row
    /// click (`openDiffViewer(for:staged:)`), cleared by `closeDiffViewer()`.
    var diffViewerChange: GitFileChange?
    /// Whether `diffViewerChange` was opened from the "Staged Changes"
    /// section — determines whether `openDiffViewer` runs `git diff` or
    /// `git diff --cached`.
    var diffViewerStaged: Bool = false
    /// The commit currently shown in `DiffViewerView`'s overlay when it was
    /// opened from `CommitHistoryView` instead of a working-tree file change
    /// (plan.md item 20 point 2). Mutually exclusive with `diffViewerChange`
    /// — whichever `openDiffViewer` variant runs most recently clears the
    /// other.
    var diffViewerCommit: GitCommit?
    var diffViewerParsedDiff: ParsedDiff = .empty
    var diffViewerIsLoading: Bool = false
    var diffViewerErrorMessage: String?

    /// `DiffViewerView`'s presentation flag — mirrors `showQuickOpen`'s
    /// "state drives visibility" pattern via a computed property instead of a
    /// second bool that could drift out of sync with `diffViewerChange`/
    /// `diffViewerCommit`.
    var showDiffViewer: Bool { diffViewerChange != nil || diffViewerCommit != nil }

    // MARK: - Find All References / Rename Symbol

    /// Results of the most recent "Find All References" (⌥⇧F12), shown in
    /// `ReferencesPanelView`. Reuses `SearchResult` (mapped from each
    /// `DefinitionLocation` by reading that file's line content) so the
    /// panel can reuse `SearchPanelView`'s exact file-grouped row rendering.
    var referencesResults: [SearchResult] = []
    /// The identifier `referencesResults` was searched for — display only.
    var referencesSymbol: String = ""
    var isFindingReferences: Bool = false
    /// A pending cross-view "jump to this location" request — set by
    /// `navigateTo(_:)` (e.g. a References panel row click) and consumed by
    /// `EditorView`/`Coordinator.consumePendingNavigation` once the target
    /// file's content is loaded into the editor.
    var pendingNavigationTarget: NavigationRequest?

    // MARK: - Document Symbols (Go to Symbol / Outline / Breadcrumbs)

    /// The active tab's document-symbol tree — the single source the ⇧⌘O
    /// "Go to Symbol" palette mode, the Outline sidebar panel, and the
    /// breadcrumbs bar (via `breadcrumbPath`) all read from, so none of them
    /// issue their own LSP requests. Kept in sync by `loadDocumentSymbols(for:)`
    /// (refetched on every tab switch) and `scheduleDocumentSymbolsRefresh`
    /// (debounced after edits).
    var documentSymbols: [DocumentSymbol] = []
    /// Per-file cache keyed by path, so switching back to a previously-visited
    /// tab shows its last-known symbol tree instantly while a fresh request
    /// for it is still in flight, rather than a blank Outline/breadcrumb for
    /// the round-trip.
    @ObservationIgnored private var documentSymbolsCache: [String: [DocumentSymbol]] = [:]
    @ObservationIgnored private var documentSymbolsRefreshTask: Task<Void, Never>?

    /// The chain of symbols (outermost → innermost) containing the active
    /// tab's cursor line, derived from `documentSymbols` — feeds the
    /// breadcrumbs bar in `EditorContainerView`. Empty when there's no active
    /// tab, no symbols loaded yet, or the cursor sits outside every symbol's
    /// range.
    var breadcrumbPath: [DocumentSymbol] {
        guard let line = focusedTab?.cursorLine else { return [] }
        return breadcrumbSymbolPath(in: documentSymbols, containingLine: line)
    }

    // Blame data keyed by file path.
    var blameCache: [String: [Int: BlameLine]] = [:]

    // MARK: - Git Gutter Change Indicators

    /// Per-open-file, per-line git change classification relative to
    /// `HEAD` — the source `GutterView`'s change bar reads from (via
    /// `EditorContainerView`/`EditorView`, the same way `diagnostics` is
    /// sourced). Populated by `refreshGitLineChanges(for:)` and
    /// `scheduleGitLineChangesRefresh`.
    var gitLineChanges: [URL: [Int: GitLineChangeType]] = [:]
    @ObservationIgnored private var gitLineChangesRefreshTask: Task<Void, Never>?

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

    // MARK: - Editor Groups (Split Editor)

    /// `side`'s open tabs — primary is `openTabs` directly; secondary is
    /// `secondaryGroup?.tabs`, empty when not split.
    func tabs(in side: EditorGroupSide) -> [TabModel] {
        switch side {
        case .primary:   return openTabs
        case .secondary: return secondaryGroup?.tabs ?? []
        }
    }

    func activeTabId(in side: EditorGroupSide) -> UUID? {
        switch side {
        case .primary:   return activeTabId
        case .secondary: return secondaryGroup?.activeTabId
        }
    }

    func activeTab(in side: EditorGroupSide) -> TabModel? {
        tabs(in: side).first { $0.id == activeTabId(in: side) }
    }

    /// The focused group's active tab — the "current file" group-aware
    /// commands act on. Identical to `activeTab` (primary) while unsplit.
    var focusedTab: TabModel? { activeTab(in: focusedGroup) }

    private func setTabs(_ tabs: [TabModel], in side: EditorGroupSide) {
        switch side {
        case .primary:   openTabs = tabs
        case .secondary: secondaryGroup?.tabs = tabs
        }
    }

    private func setActiveTabId(_ id: UUID?, in side: EditorGroupSide) {
        switch side {
        case .primary:   activeTabId = id
        case .secondary: secondaryGroup?.activeTabId = id
        }
    }

    /// The group currently holding an open tab with id `id`, if any. Tab
    /// ids are unique per group — `splitEditorRight()` gives the secondary
    /// copy of a file its own fresh `TabModel`/id rather than sharing the
    /// source tab's — so a plain membership check is unambiguous.
    private func side(ofTab id: UUID) -> EditorGroupSide? {
        if openTabs.contains(where: { $0.id == id }) { return .primary }
        if secondaryGroup?.tabs.contains(where: { $0.id == id }) == true { return .secondary }
        return nil
    }

    /// The group with an open tab for `url`, if any (used by `openFile` to
    /// reveal/focus an already-open file rather than duplicating it).
    private func side(ofOpenFile url: URL) -> EditorGroupSide? {
        if openTabs.contains(where: { $0.fileURL == url }) { return .primary }
        if secondaryGroup?.tabs.contains(where: { $0.fileURL == url }) == true { return .secondary }
        return nil
    }

    private func isFileOpen(_ url: URL) -> Bool {
        openTabs.contains { $0.fileURL == url } || (secondaryGroup?.tabs.contains { $0.fileURL == url } ?? false)
    }

    /// Applies `mutate` to every open tab (in either group) whose `fileURL`
    /// equals `url` — used by URL-driven bulk updates (external file-change
    /// reload, discard changes, workspace search & replace) so a file split
    /// into both groups doesn't leave one pane showing stale content.
    private func updateTabs(withFileURL url: URL, _ mutate: (inout TabModel) -> Void) {
        for side: EditorGroupSide in [.primary, .secondary] {
            var groupTabs = tabs(in: side)
            guard let index = groupTabs.firstIndex(where: { $0.fileURL == url }) else { continue }
            mutate(&groupTabs[index])
            setTabs(groupTabs, in: side)
        }
    }

    /// "Split Editor Right" (⌘\, plan.md item 22): opens the focused
    /// group's active tab's file as an INDEPENDENT tab (its own id, cursor,
    /// scroll position) in the secondary group, creating that group first
    /// if this is the first split — matching VS Code, which duplicates the
    /// file into a second, independent tab rather than sharing one `TabModel`
    /// across groups. Repeated ⌘\ on the same file activates the existing
    /// secondary copy instead of piling up duplicates (mirrors `openFile`'s
    /// own open-or-activate rule). No-op for an unsaved Untitled tab (no
    /// `fileURL` to duplicate) or when nothing is focused.
    func splitEditorRight() {
        guard let source = focusedTab, let url = source.fileURL else { return }

        if secondaryGroup == nil {
            secondaryGroup = EditorGroup()
        }

        if let existing = secondaryGroup?.tabs.first(where: { $0.fileURL == url }) {
            secondaryGroup?.activeTabId = existing.id
            focusedGroup = .secondary
            return
        }

        var copy = TabModel(title: source.title)
        copy.fileURL      = url
        copy.content      = source.content
        copy.language     = source.language
        copy.isDirty      = source.isDirty
        copy.cursorLine   = source.cursorLine
        copy.cursorColumn = source.cursorColumn

        secondaryGroup?.tabs.append(copy)
        secondaryGroup?.activeTabId = copy.id
        focusedGroup = .secondary
    }

    /// Records `tabId`'s cursor position (in `side`) and makes `side` the
    /// focused group — cursor movement (including a click) is itself a
    /// focus event (plan.md item 22 point 3). Feeds the status bar's
    /// "Ln n Col n", and — via `focusedTab` — the breadcrumbs bar.
    func setCursorPosition(tabId: UUID, in side: EditorGroupSide, line: Int, column: Int) {
        var groupTabs = tabs(in: side)
        guard let index = groupTabs.firstIndex(where: { $0.id == tabId }) else { return }
        groupTabs[index].cursorLine   = line
        groupTabs[index].cursorColumn = column
        setTabs(groupTabs, in: side)
        focusedGroup = side
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
        fileWatchService: FileWatchService = FileWatchService(),
        prettierService: PrettierService = PrettierService()
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
        self.prettierService = prettierService

        // Default to one terminal session at launch — matches the
        // pre-multi-terminal behavior (plan.md item 21 point 4): a user who
        // never touches this feature shouldn't see an empty terminal panel
        // or be forced to click "+" first.
        newTerminalSession()
    }

    // MARK: - Methods

    /// Opens a file URL in a new tab, or activates the existing tab if
    /// already open. If the file is already open in EITHER group, this
    /// reveals it there (switching focus to that group) rather than opening
    /// a duplicate; otherwise it opens into the currently focused group
    /// (`.primary` while unsplit, so single-pane behavior is unchanged —
    /// plan.md item 22). Use `splitEditorRight()` to deliberately open the
    /// same file a second time as an independent tab in the other group.
    func openFile(_ url: URL) async {
        if let existingSide = side(ofOpenFile: url),
           let existingId = tabs(in: existingSide).first(where: { $0.fileURL == url })?.id {
            setActiveTabId(existingId, in: existingSide)
            focusedGroup = existingSide
            if existingSide == .primary { await persistSession() }
            return
        }

        let side = focusedGroup
        let language = Language.detect(from: url)

        // Image files (plan.md item 26, "G1") never go through the text
        // decode path at all — `FileService.readFile` would happily decode
        // arbitrary binary bytes as ISO-Latin-1 "text" (see its fallback),
        // producing a garbage string that's expensive to hold and never
        // rendered (`ImagePreviewView` reads the file itself via `NSImage`).
        // No LSP hookup either: there's no document content for a language
        // server to reason about.
        guard language != .image else {
            var tab = TabModel(title: url.lastPathComponent)
            tab.fileURL = url
            tab.language = language
            tab.isDirty = false

            var groupTabs = tabs(in: side)
            groupTabs.append(tab)
            setTabs(groupTabs, in: side)
            setActiveTabId(tab.id, in: side)

            statusMessage = "Opened \(url.lastPathComponent)"
            AppState.registerRecentPath(url)
            await fileWatchService.watchFile(url)
            if side == .primary { await persistSession() }
            return
        }

        do {
            let content = try await fileService.readFile(url)
            var tab = TabModel(title: url.lastPathComponent)
            tab.fileURL = url
            tab.content = content
            tab.language = language
            tab.isDirty = false

            var groupTabs = tabs(in: side)
            groupTabs.append(tab)
            setTabs(groupTabs, in: side)
            setActiveTabId(tab.id, in: side)

            statusMessage = "Opened \(url.lastPathComponent)"
            AppState.registerRecentPath(url)
            await fileWatchService.watchFile(url)
            if side == .primary { await persistSession() }

            // Bring up the language server (no-op if none is installed) and tell
            // it about the newly opened document. Fired unstructured so file
            // opening itself stays instant.
            if let workspace {
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

    /// Closes the tab with the given ID — looked up in whichever group
    /// currently contains it (see `side(ofTab:)`) — activating an adjacent
    /// tab in that same group if needed. Closing the secondary group's last
    /// tab collapses back to single-pane (plan.md item 22 point 4).
    func closeTab(_ id: UUID) {
        guard let side = side(ofTab: id) else { return }

        var groupTabs = tabs(in: side)
        guard let index = groupTabs.firstIndex(where: { $0.id == id }) else { return }
        let closedURL = groupTabs[index].fileURL

        // LSP/file-watch/diagnostics/gutter state is keyed by file URL and
        // shared by both groups when the same file is split into each — only
        // tear it down once the closed tab's file isn't ALSO open in the
        // other group (a still-open twin tab still needs it).
        if let url = closedURL, !tabs(in: side.other).contains(where: { $0.fileURL == url }) {
            Task {
                await self.lspManager.didClose(fileURL: url)
                await self.fileWatchService.stopWatchingFile(url)
            }
            diagnostics.removeValue(forKey: url)
            gitLineChanges.removeValue(forKey: url)
        }

        groupTabs.remove(at: index)
        setTabs(groupTabs, in: side)

        // If we just closed the active tab, select an adjacent one.
        if activeTabId(in: side) == id {
            if groupTabs.isEmpty {
                setActiveTabId(nil, in: side)
                // documentSymbols/breadcrumbs are refreshed centrally from
                // `focusedTab`'s identity (see `EditorContainerView`'s
                // document-symbols task), so no manual clear is needed here.
            } else {
                // Prefer the tab now at the same index; fall back to the last tab.
                let newIndex = min(index, groupTabs.count - 1)
                setActiveTabId(groupTabs[newIndex].id, in: side)
            }
        }

        // Closing the secondary group's last tab collapses back to single-pane.
        if side == .secondary, groupTabs.isEmpty {
            secondaryGroup = nil
            if focusedGroup == .secondary { focusedGroup = .primary }
        }

        // Session persistence only tracks the primary group (plan.md item
        // 22: split layout itself isn't restored across relaunches).
        if side == .primary {
            Task { await self.persistSession() }
        }
    }

    /// Activates the tab with the given ID (e.g. a tab-bar click) in
    /// whichever group contains it, makes that group focused (a tab click
    /// is itself a focus event), and — for the primary group — persists the
    /// new selection so a relaunch restores the same active tab.
    func activateTab(_ id: UUID) {
        guard let side = side(ofTab: id) else { return }
        setActiveTabId(id, in: side)
        focusedGroup = side
        if side == .primary {
            Task { await self.persistSession() }
        }
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

    // MARK: - Document Symbols (Go to Symbol / Outline / Breadcrumbs)

    /// Fetches `textDocument/documentSymbol` for `tab`'s file and populates
    /// `documentSymbols`. Called from a single `.task(id:)` in
    /// `EditorContainerView` keyed to the FOCUSED group's active tab, not
    /// each pane's own tab — `documentSymbols`/`breadcrumbPath` are a single
    /// global tree (unlike `diagnostics`/`gitLineChanges`, which are per-URL
    /// dictionaries), so only the focused pane may ever drive them, or two
    /// panes' fetches would race to overwrite each other (plan.md item 22).
    /// Shows the cached tree for this file (if any) immediately so switching
    /// back to a previously-visited tab doesn't blank the Outline panel/
    /// breadcrumbs for the round-trip, then replaces it with the fresh
    /// result — unless focus has already moved elsewhere by the time the
    /// response lands, in which case that move's own fetch owns what's shown.
    func loadDocumentSymbols(for tab: TabModel) async {
        guard let fileURL = tab.fileURL else {
            documentSymbols = []
            return
        }
        documentSymbols = documentSymbolsCache[fileURL.path] ?? []

        guard let symbols = try? await lspManager.documentSymbols(fileURL: fileURL) else { return }
        guard !Task.isCancelled, focusedTab?.id == tab.id else { return }
        documentSymbolsCache[fileURL.path] = symbols
        documentSymbols = symbols
    }

    /// Debounces a `textDocument/documentSymbol` refetch 800 ms after the
    /// last keystroke in the focused group's active tab's file (called from
    /// `updateTabContent`) — symbols don't need to track every keystroke,
    /// only be eventually consistent, matching the debounce style
    /// `EditorView.Coordinator` already uses for ghost text / completions.
    private func scheduleDocumentSymbolsRefresh(tabId: UUID, fileURL: URL) {
        documentSymbolsRefreshTask?.cancel()
        documentSymbolsRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let symbols = try? await self.lspManager.documentSymbols(fileURL: fileURL) else { return }
            guard !Task.isCancelled, self.focusedTab?.id == tabId else { return }
            self.documentSymbolsCache[fileURL.path] = symbols
            self.documentSymbols = symbols
        }
    }

    // MARK: - Git Gutter Change Indicators

    /// Recomputes the per-line git change classification for the file in
    /// `tab` and stores it in `gitLineChanges`. Called from
    /// `CodeEditorView`'s `.task(id: tab.id)` (mirroring `loadBlame(for:)`
    /// and `loadDocumentSymbols(for:)`, so it refreshes on every tab
    /// switch), and again after a successful save.
    func refreshGitLineChanges(for tab: TabModel) async {
        guard let fileURL = tab.fileURL else { return }
        guard let changes = await computeGitLineChanges(for: fileURL) else { return }
        gitLineChanges[fileURL] = changes
    }

    /// Debounces a `git diff` refetch 800 ms after the last keystroke in
    /// EITHER group's visible tab (called from `updateTabContent`) — mirrors
    /// `scheduleDocumentSymbolsRefresh`'s debounce style, but — unlike that
    /// single global tree — `gitLineChanges` is per-URL, so it's safe (and
    /// correct) for it to stay current for whichever group's tab is being
    /// edited, not just the focused one. The change bar only needs to be
    /// eventually consistent, not track every keystroke (a real `git diff`
    /// subprocess call per keystroke would be wasteful).
    private func scheduleGitLineChangesRefresh(tabId: UUID, fileURL: URL) {
        gitLineChangesRefreshTask?.cancel()
        gitLineChangesRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let changes = await self.computeGitLineChanges(for: fileURL) else { return }
            guard !Task.isCancelled,
                  let side = self.side(ofTab: tabId),
                  self.activeTabId(in: side) == tabId
            else { return }
            self.gitLineChanges[fileURL] = changes
        }
    }

    /// Runs `git diff` for `fileURL` (or, for an untracked file, synthesizes
    /// a whole-file "added" diff via `ParsedDiff.wholeFileAsAdded`, the same
    /// helper the diff viewer uses for the identical situation) and reduces
    /// it through `UnifiedDiffParser.classifyLineChanges`. Returns `nil`
    /// when there's no open workspace, no `.git` directory (mirroring
    /// `loadBlame(for:)`'s own guard), or the git/file read fails — callers
    /// treat `nil` as "leave the existing state alone" rather than clearing it.
    private func computeGitLineChanges(for fileURL: URL) async -> [Int: GitLineChangeType]? {
        guard let ws = workspace else { return nil }
        let gitDir = ws.rootURL.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else { return nil }

        let isUntracked = gitStatus.untracked.contains {
            ws.rootURL.appendingPathComponent($0.path).standardizedFileURL == fileURL.standardizedFileURL
        }

        let parsed: ParsedDiff
        if isUntracked {
            guard let content = try? await fileService.readFile(fileURL) else { return nil }
            parsed = .wholeFileAsAdded(content)
        } else {
            guard let diffText = try? await gitService.diff(path: fileURL.path, staged: false, at: ws.rootURL)
            else { return nil }
            parsed = UnifiedDiffParser.parse(diffText)
        }
        return UnifiedDiffParser.classifyLineChanges(in: parsed)
    }

    /// Whether `ConflictParser`'s raw marker-text scan should be trusted for
    /// `fileURL` — gates the editor's merge-conflict resolution UI (plan.md
    /// item 23, "D5") against a false positive on a file that merely
    /// *contains* the literal `<<<<<<<`/`=======`/`>>>>>>>` strings for an
    /// unrelated reason (e.g. a doc file explaining git conflicts) rather
    /// than an actual unresolved merge.
    ///
    /// Trusts the scan on its own (`true`) whenever there's no repo to check
    /// against, or `gitStatus` hasn't been populated yet (its all-empty
    /// default is indistinguishable from "a freshly opened, genuinely clean
    /// repo" — in that rare ambiguous case this errs toward showing the UI
    /// rather than risking hiding a real conflict). Once a real status is in
    /// hand, only a file git itself lists as unmerged (`gitStatus.conflicted`,
    /// matched the same way `computeGitLineChanges` matches `untracked`)
    /// opens the gate — any other known git state (clean, modified,
    /// untracked, staged) means this can't be a live conflict, since real
    /// conflict markers are themselves an uncommitted change git would have
    /// flagged as unmerged.
    func isConflictScanTrusted(for fileURL: URL) -> Bool {
        guard let ws = workspace else { return true }

        func matches(_ change: GitFileChange) -> Bool {
            ws.rootURL.appendingPathComponent(change.path).standardizedFileURL == fileURL.standardizedFileURL
        }

        if gitStatus.conflicted.contains(where: matches) { return true }

        let statusLoaded = !gitStatus.branch.isEmpty
            || !gitStatus.staged.isEmpty || !gitStatus.unstaged.isEmpty
            || !gitStatus.untracked.isEmpty || !gitStatus.conflicted.isEmpty
        return !statusLoaded
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
        async let ct   = settingsService.value(for: "customThemes",            default: [EditorTheme]())

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
        customThemes            = await ct
        let themeId             = await th
        currentTheme            = allThemes.first(where: { $0.id == themeId }) ?? EditorTheme.named(themeId)

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

    // MARK: - VS Code theme import (plan.md item 27, "G4")

    /// Every selectable theme — built-ins plus user-imported VS Code
    /// themes — for `SettingsView`'s theme picker.
    var allThemes: [EditorTheme] { EditorTheme.all + customThemes }

    /// Reads `url`, parses it as a VS Code theme JSON file via
    /// `VSCodeThemeImporter`, and — on success — adds it to `customThemes`
    /// (persisted the same way every other setting is, via
    /// `settingsService`) and selects it immediately. Parse failures surface
    /// via `statusMessage` rather than throwing further, matching this
    /// app's other file-picker-triggered actions (e.g. `cloneRepository`) —
    /// a malformed or unrelated JSON file fails cleanly, no crash.
    func importVSCodeTheme(from url: URL) async {
        guard
            let data = try? Data(contentsOf: url),
            let json = String(data: data, encoding: .utf8)
        else {
            statusMessage = "Couldn't read \"\(url.lastPathComponent)\"."
            return
        }

        let id = uniqueCustomThemeId(from: url.deletingPathExtension().lastPathComponent)

        do {
            let theme = try VSCodeThemeImporter.parse(json, id: id)
            customThemes.append(theme)
            persistSetting(customThemes, for: "customThemes")
            currentTheme = theme
            persistSetting(theme.id, for: "theme")
            statusMessage = "Imported theme \"\(theme.name)\""
        } catch {
            statusMessage = "\"\(url.lastPathComponent)\" isn't a recognized VS Code theme file."
        }
    }

    /// Slugifies `base` (the file's name, sans extension) into a theme id,
    /// disambiguating against every existing built-in/custom id so
    /// re-importing a same-named theme (or two themes that happen to share
    /// a display name) never silently overwrites another entry.
    private func uniqueCustomThemeId(from base: String) -> String {
        let slug = base
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let candidateBase = "custom-\(slug.isEmpty ? "imported-theme" : slug)"

        let existingIds = Set(EditorTheme.all.map(\.id) + customThemes.map(\.id))
        guard existingIds.contains(candidateBase) else { return candidateBase }

        var suffix = 2
        while existingIds.contains("\(candidateBase)-\(suffix)") { suffix += 1 }
        return "\(candidateBase)-\(suffix)"
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

    // MARK: - Format on Save

    /// Web languages `PrettierService` is attempted for when LSP formatting
    /// isn't available — matches the file types `NPMScriptService`/the
    /// npm-script-runner feature already targets.
    private static let prettierLanguages: Set<Language> = [
        .typescript, .javascript, .css, .html, .json, .markdown,
    ]

    /// Runs the configured formatter(s) for `tab` when `editorFormatOnSave`
    /// is on: the active LSP server first, then — for web languages only —
    /// the workspace's own local Prettier install. Returns `nil` when
    /// format-on-save is off, `tab` has no file URL, or neither formatter
    /// produced a result (no server running / no local Prettier binary / no
    /// changes needed); callers should keep the tab's existing content then.
    private func formattedContent(for tab: TabModel) async -> String? {
        guard editorFormatOnSave, let url = tab.fileURL else { return nil }

        if let formatted = try? await lspManager.formatting(
            fileURL: url,
            content: tab.content,
            tabSize: editorTabSize,
            insertSpaces: editorInsertSpaces
        ) {
            return formatted
        }

        guard
            AppState.prettierLanguages.contains(tab.language),
            let ws = workspace
        else { return nil }

        return try? await prettierService.format(
            fileURL: url,
            content: tab.content,
            workspaceRoot: ws.rootURL
        )
    }

    /// Saves the content of the currently active tab to disk. Acts on the
    /// FOCUSED group's active tab — "the current file" for Cmd+S is
    /// whichever pane the user was last in (plan.md item 22).
    ///
    /// Image tabs (plan.md item 26, "G1") are never dirty and are skipped
    /// here explicitly rather than relying on that alone — `saveTab` writes
    /// `tab.content` unconditionally (it doesn't re-check `isDirty`), and an
    /// image tab's `content` is always the empty string (never populated;
    /// see `openFile`'s image branch), so without this guard Cmd+S on an
    /// image tab would silently truncate the file on disk to zero bytes.
    func saveActiveTab() async {
        guard let tab = focusedTab, tab.language != .image else { return }
        await saveTab(id: tab.id, in: focusedGroup)
    }

    /// Saves `id`'s content (in `side`) to disk, running format-on-save
    /// first. Shared by `saveActiveTab()` (Cmd+S) and the debounced
    /// auto-save timer in `updateTabContent`, which must target the EDITED
    /// tab directly rather than "whichever tab is focused" — those can
    /// differ for a moment if focus moves to another pane while an
    /// auto-save for the previous edit is still in flight.
    private func saveTab(id: UUID, in side: EditorGroupSide) async {
        var groupTabs = tabs(in: side)
        guard let index = groupTabs.firstIndex(where: { $0.id == id }),
              let url = groupTabs[index].fileURL
        else { return }
        var tab = groupTabs[index]

        if let formatted = await formattedContent(for: tab) {
            tab.content = formatted
            groupTabs[index].content = formatted
            setTabs(groupTabs, in: side)
        }

        do {
            try await fileService.writeFile(url, content: tab.content)
            groupTabs = tabs(in: side)
            if let i = groupTabs.firstIndex(where: { $0.id == id }) {
                groupTabs[i].isDirty = false
                // A completed save overwrites whatever triggered the
                // "changed on disk" banner, so it's no longer relevant.
                groupTabs[i].externallyModified = false
                setTabs(groupTabs, in: side)
                tab = groupTabs[i]
            }
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            statusMessage = "Error saving \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }

        // A save changes the file-vs-HEAD relationship — recompute the
        // gutter's change bar for it now rather than waiting for the next
        // debounced edit or tab switch.
        await refreshGitLineChanges(for: tab)

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

    /// Acts on the focused group's active tab, same as `saveActiveTab()`.
    /// Guarded against image tabs for the same reason `saveActiveTab()` is —
    /// `tab.content` is always empty for one, so "Save As" would write an
    /// empty file rather than copying the image.
    func saveActiveTabAs() async {
        guard let tab = focusedTab, tab.language != .image else { return }
        let side = focusedGroup
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
            var groupTabs = tabs(in: side)
            if let index = groupTabs.firstIndex(where: { $0.id == tab.id }) {
                groupTabs[index].fileURL    = newURL
                groupTabs[index].title      = newURL.lastPathComponent
                groupTabs[index].isDirty    = false
                groupTabs[index].externallyModified = false
                groupTabs[index].language   = Language.detect(from: newURL)
                setTabs(groupTabs, in: side)
            }
            statusMessage = "Saved \(newURL.lastPathComponent)"
            AppState.registerRecentPath(newURL)
            if let previousURL = tab.fileURL {
                await fileWatchService.stopWatchingFile(previousURL)
                gitLineChanges.removeValue(forKey: previousURL)
            }
            await fileWatchService.watchFile(newURL)
            groupTabs = tabs(in: side)
            if let index = groupTabs.firstIndex(where: { $0.id == tab.id }) {
                await refreshGitLineChanges(for: groupTabs[index])
            }
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Acts on the focused group's active tab, same as `saveActiveTab()`.
    /// Skips image tabs — there's no text buffer to revert (they're never
    /// dirty in the first place), and re-decoding the image's bytes as text
    /// would just be wasted work.
    func revertActiveTab() async {
        guard let tab = focusedTab, tab.language != .image, let url = tab.fileURL else { return }
        let side = focusedGroup
        do {
            let content = try await fileService.readFile(url)
            var groupTabs = tabs(in: side)
            if let index = groupTabs.firstIndex(where: { $0.id == tab.id }) {
                groupTabs[index].content = content
                groupTabs[index].isDirty = false
                groupTabs[index].externallyModified = false
                setTabs(groupTabs, in: side)
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
        gitLineChanges = [:]

        workspace    = nil
        fileTree     = []
        gitStatus    = GitStatus()
        openTabs     = []
        activeTabId  = nil
        secondaryGroup = nil
        focusedGroup   = .primary
        statusMessage = ""
        diffViewerChange = nil
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
        selectedFrameId = nil
        debugConsoleEntries = []
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
        selectedFrameId  = nil
        // Watch expressions themselves persist across sessions (they're
        // user-authored, not session state) — only their last-evaluated
        // values go stale once there's no debuggee to evaluate against.
        watchExpressions = watchExpressions.map {
            var expr = $0
            expr.lastValue = nil
            expr.lastType  = nil
            expr.lastError = nil
            return expr
        }
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
            selectedFrameId = debugStackFrames.first?.id
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
        await reevaluateWatchExpressions()
    }

    // MARK: - Watch Expressions (plan.md item 24)

    /// Selects a call-stack frame as the target for subsequent variable
    /// fetches, watch-expression evaluation, and REPL evaluation —
    /// `DebugSidebarView`'s call-stack rows call this on click.
    func selectStackFrame(_ frameId: Int) async {
        guard selectedFrameId != frameId else { return }
        selectedFrameId = frameId
        do {
            debugVariables = try await debugService.fetchVariables(frameId: frameId)
        } catch {
            debugOutput += "[Athena] Error fetching variables: \(error.localizedDescription)\n"
        }
        await reevaluateWatchExpressions()
    }

    func addWatchExpression(_ expression: String) {
        let updated = WatchExpression.appending(expression, to: watchExpressions)
        guard updated.count != watchExpressions.count else { return }
        watchExpressions = updated
        Task { await reevaluateWatchExpressions() }
    }

    func removeWatchExpression(_ id: UUID) {
        watchExpressions = WatchExpression.removing(id, from: watchExpressions)
    }

    /// Re-evaluates every watch expression against the currently selected
    /// stack frame — called on every pause (via `refreshDebugState`) and
    /// after adding a new expression or switching the selected frame. A
    /// failing expression (e.g. an out-of-scope variable) records its error
    /// inline on that row rather than throwing/crashing or touching
    /// `statusMessage`.
    func reevaluateWatchExpressions() async {
        guard case .paused = debugState, !watchExpressions.isEmpty else { return }
        let frameId = selectedFrameId ?? debugStackFrames.first?.id
        var results: [UUID: WatchEvaluationOutcome] = [:]
        for expr in watchExpressions {
            do {
                let evaluated = try await debugService.evaluate(
                    expression: expr.expression, frameId: frameId, context: "watch")
                results[expr.id] = .success(evaluated)
            } catch {
                results[expr.id] = .failure(error.localizedDescription)
            }
        }
        watchExpressions = WatchExpression.applying(results, to: watchExpressions)
    }

    // MARK: - Debug Console REPL (plan.md item 24)

    /// Evaluates a typed expression in the debug console against the
    /// currently selected paused frame, appending it and its result (or
    /// error) to the transcript. No-op while not paused — `DebugConsoleView`
    /// also disables its input field in that state, this is the belt-and-
    /// suspenders guard against a stale Enter keypress racing a resume.
    func evaluateInConsole(_ expression: String) async {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, case .paused = debugState else { return }
        let frameId = selectedFrameId ?? debugStackFrames.first?.id
        do {
            let evaluated = try await debugService.evaluate(
                expression: trimmed, frameId: frameId, context: "repl")
            debugConsoleEntries.append(DebugConsoleEntry(expression: trimmed, result: evaluated.result, isError: false))
        } catch {
            debugConsoleEntries.append(
                DebugConsoleEntry(expression: trimmed, result: error.localizedDescription, isError: true))
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

    /// Refreshes the Git status for the current workspace. Also keeps
    /// `branches` (the `StatusBarView` branch-switcher's data source) fresh
    /// opportunistically — best-effort, so a branch-listing failure doesn't
    /// clobber a successful status refresh's `statusMessage`.
    func refreshGitStatus() async {
        guard let workspace else { return }

        do {
            gitStatus = try await gitService.status(at: workspace.rootURL)
        } catch {
            statusMessage = "Git error: \(error.localizedDescription)"
        }

        branches = (try? await gitService.branches(at: workspace.rootURL)) ?? branches
    }

    // MARK: - Branches

    /// Checks out `name` and refreshes Git status (which also refreshes
    /// `branches`) — the `StatusBarView` branch-switcher's selection action
    /// (plan.md item 20 point 1).
    func checkoutBranch(_ name: String) async {
        guard let workspace else { return }
        do {
            try await gitService.checkout(name, at: workspace.rootURL)
        } catch {
            statusMessage = "Checkout failed: \(error.localizedDescription)"
            return
        }
        await refreshGitStatus()
    }

    /// Creates `name` off HEAD and checks it out in one step
    /// (`git checkout -b`, see `GitService.createBranch`), then refreshes —
    /// the branch-switcher's "Create New Branch…" entry.
    func createAndCheckoutBranch(named name: String) async {
        guard let workspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try await gitService.createBranch(trimmed, at: workspace.rootURL)
        } catch {
            statusMessage = "Create branch failed: \(error.localizedDescription)"
            return
        }
        await refreshGitStatus()
    }

    // MARK: - Commit History

    /// Results of the most recent `git log`, shown in `CommitHistoryView`
    /// (plan.md item 20 point 2). Populated by `refreshCommitHistory()`.
    var commitHistory: [GitCommit] = []
    var isLoadingCommitHistory: Bool = false
    var commitHistoryErrorMessage: String?

    func refreshCommitHistory(limit: Int = 50) async {
        guard let workspace else { return }
        isLoadingCommitHistory = true
        commitHistoryErrorMessage = nil
        defer { isLoadingCommitHistory = false }

        do {
            commitHistory = try await gitService.log(at: workspace.rootURL, limit: limit)
        } catch {
            commitHistoryErrorMessage = "Git error: \(error.localizedDescription)"
        }
    }

    // MARK: - Clone Repository

    /// Clones `urlString` into a new folder under `destinationParent` (named
    /// after the repo, via `GitService.repoFolderName(from:)`) and, on
    /// success, opens the cloned folder as the workspace — the Welcome
    /// screen's "Clone Repository" flow (plan.md item 20 point 3). A live
    /// progress bar is out of scope for this pass; progress/failure surface
    /// through `statusMessage` instead, matching every other long-running Git
    /// operation in this class.
    func cloneRepository(urlString: String, destinationParent: URL) async {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        let folderName = GitService.repoFolderName(from: trimmedURL)
        let destination = destinationParent.appendingPathComponent(folderName)
        statusMessage = "Cloning \(trimmedURL)…"

        do {
            try await gitService.clone(url: trimmedURL, into: destination)
        } catch {
            statusMessage = "Clone failed: \(error.localizedDescription)"
            return
        }

        statusMessage = "Cloned \(folderName)"
        await openWorkspace(destination)
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

        if let content = try? await fileService.readFile(url) {
            updateTabs(withFileURL: url) { tab in
                tab.content = content
                tab.isDirty = false
                tab.externallyModified = false
            }
        }
    }

    // MARK: - Diff Viewer

    /// Opens `DiffViewerView` for `change` and loads/parses its diff text.
    ///
    /// Untracked files (`status == "??"`, see `GitService.status`) have no
    /// meaningful `git diff` against `HEAD` — git prints nothing — so those
    /// are rendered as a synthetic all-green "added" hunk of the whole file's
    /// current contents instead (plan.md item 18 point 4), read the same way
    /// `discardChanges`/file-watch reloads read a file directly off disk.
    func openDiffViewer(for change: GitFileChange, staged: Bool) async {
        diffViewerChange       = change
        diffViewerCommit       = nil
        diffViewerStaged       = staged
        diffViewerParsedDiff   = .empty
        diffViewerErrorMessage = nil
        diffViewerIsLoading    = true
        defer { diffViewerIsLoading = false }

        guard let workspace else { return }
        let url = workspace.rootURL.appendingPathComponent(change.path)

        if change.status == "??" {
            do {
                let content = try await fileService.readFile(url)
                diffViewerParsedDiff = .wholeFileAsAdded(content)
            } catch {
                diffViewerErrorMessage = "Unable to read file — it may be binary."
            }
            return
        }

        do {
            let text = try await gitService.diff(path: change.path, staged: staged, at: workspace.rootURL)
            diffViewerParsedDiff = UnifiedDiffParser.parse(text)
        } catch {
            diffViewerErrorMessage = "Git error: \(error.localizedDescription)"
        }
    }

    /// Opens `DiffViewerView` for `commit`'s full changes (`git show <hash>`),
    /// entered from `CommitHistoryView`'s row click (plan.md item 20 point 2).
    /// Reuses the same `ParsedDiff`/`UnifiedDiffParser`/`DiffViewerView`
    /// rendering path as `openDiffViewer(for:staged:)` above rather than a
    /// second diff renderer. A commit can touch multiple files and
    /// `ParsedDiff` doesn't track a file path per hunk, so `DiffViewerView`
    /// renders every hunk without per-file syntax highlighting in this mode.
    func openDiffViewer(forCommit commit: GitCommit) async {
        diffViewerChange       = nil
        diffViewerCommit       = commit
        diffViewerStaged       = false
        diffViewerParsedDiff   = .empty
        diffViewerErrorMessage = nil
        diffViewerIsLoading    = true
        defer { diffViewerIsLoading = false }

        guard let workspace else { return }

        do {
            let text = try await gitService.diff(commit: commit.hash, at: workspace.rootURL)
            diffViewerParsedDiff = UnifiedDiffParser.parse(text)
        } catch {
            diffViewerErrorMessage = "Git error: \(error.localizedDescription)"
        }
    }

    /// Opens `DiffViewerView` showing one merge-conflict region's "ours" vs
    /// "theirs" content as a diff — the gutter menu's "Compare" action
    /// (plan.md item 23, "D5"). Reuses `diffViewerChange`/
    /// `diffViewerParsedDiff` exactly like `openDiffViewer(for:staged:)`
    /// above, so the view's existing filename/path header and per-file
    /// syntax-highlighting language detection come along for free; unlike
    /// that method, this never touches disk or git — `region.compareDiff`
    /// is synthesized entirely from content already parsed out of the live
    /// editor buffer.
    func openDiffViewer(forConflict region: ConflictRegion, in fileURL: URL) {
        diffViewerChange       = GitFileChange(path: fileURL.path, status: "UU")
        diffViewerCommit       = nil
        diffViewerStaged       = false
        diffViewerErrorMessage = nil
        diffViewerIsLoading    = false
        diffViewerParsedDiff   = region.compareDiff
    }

    /// Dismisses the diff viewer overlay.
    func closeDiffViewer() {
        diffViewerChange = nil
        diffViewerCommit = nil
    }

    /// Updates the text content of a tab (in whichever group currently
    /// contains it) and marks it as dirty.
    func updateTabContent(_ id: UUID, content: String) {
        guard let side = side(ofTab: id) else { return }
        var groupTabs = tabs(in: side)
        guard let index = groupTabs.firstIndex(where: { $0.id == id }) else { return }
        groupTabs[index].content = content
        groupTabs[index].isDirty = true
        setTabs(groupTabs, in: side)

        if let url = groupTabs[index].fileURL {
            Task { await self.lspManager.didChange(fileURL: url, content: content) }
            if activeTabId(in: side) == id {
                // Per-URL keyed state (the gutter's change bar) refreshes for
                // either group's visible tab, regardless of focus.
                scheduleGitLineChangesRefresh(tabId: id, fileURL: url)
                // documentSymbols/breadcrumbs are a single global tree — only
                // the FOCUSED group's visible tab may drive them (see
                // `loadDocumentSymbols`'s doc comment).
                if side == focusedGroup {
                    scheduleDocumentSymbolsRefresh(tabId: id, fileURL: url)
                }
            }
        }

        // Auto-save: debounce 1 s after the last keystroke. Targets the
        // EDITED tab directly (not "the active/focused tab") — see
        // `saveTab(id:in:)`'s doc comment.
        if UserDefaults.standard.bool(forKey: "athenaAutoSave") {
            autoSaveTask?.cancel()
            autoSaveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.saveTab(id: id, in: side)
            }
        }
    }

    /// Flips a markdown tab's Source/Preview flag (plan.md item 26, "G2") —
    /// looked up by id in whichever group currently holds it, mirroring
    /// `updateTabContent`'s side-resolution. A plain, synchronous mutation:
    /// there's no re-render debounce here (unlike live-as-you-type preview,
    /// out of scope for this pass) — the preview is simply recomputed once,
    /// on the switch itself, from whatever `tab.content` holds right now.
    func toggleMarkdownPreview(_ id: UUID) {
        guard let side = side(ofTab: id) else { return }
        var groupTabs = tabs(in: side)
        guard let index = groupTabs.firstIndex(where: { $0.id == id }) else { return }
        groupTabs[index].isMarkdownPreview.toggle()
        setTabs(groupTabs, in: side)
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

            updateTabs(withFileURL: url) { tab in
                tab.content = replaced
                tab.isDirty = false
                tab.externallyModified = false
            }
        }

        statusMessage = filesChanged == 0
            ? "No occurrences of \"\(query)\" found"
            : "Replaced \(totalOccurrences) occurrence\(totalOccurrences == 1 ? "" : "s") across \(filesChanged) file\(filesChanged == 1 ? "" : "s")"

        return (totalOccurrences, filesChanged)
    }

    // MARK: - Find All References

    /// Requests `textDocument/references` at (0-based) `line`/`character` in
    /// `fileURL` and populates `referencesResults`/`referencesSymbol`,
    /// showing the References bottom panel. Each result's line content is
    /// read from the corresponding open tab's in-memory content when one
    /// exists (the LSP server's view of an open file is that content, not
    /// necessarily what's on disk) and from `fileService` otherwise.
    func findReferences(fileURL: URL, line: Int, character: Int) async {
        isFindingReferences = true
        showBottomPanel = true
        activeBottomPanel = .references
        referencesResults = []
        // `focusedTab`, not `activeTab` — this is invoked from whichever
        // pane's editor is actually focused (its Coordinator gates
        // `onFindReferences` on `firstResponder`), which may be the
        // secondary group.
        referencesSymbol = Self.identifier(inLine: focusedTab?.content, line: line, character: character)
            ?? fileURL.lastPathComponent

        defer { isFindingReferences = false }

        guard let locations = try? await lspManager.references(
            fileURL: fileURL, line: line, character: character
        ), !locations.isEmpty else {
            statusMessage = "No references found"
            return
        }

        // Cache each file's content the first time it's needed — a symbol
        // commonly has multiple references in the same file, and re-reading
        // (or re-scanning an open tab's content) once per *location* instead
        // of once per *file* would be wasted, repeated I/O.
        var contentCache: [URL: String] = [:]
        var results: [SearchResult] = []

        for location in locations {
            let content: String
            if let cached = contentCache[location.fileURL] {
                content = cached
            } else if let openContent = openTabs.first(where: { $0.fileURL == location.fileURL })?.content {
                content = openContent
                contentCache[location.fileURL] = openContent
            } else if let read = try? await fileService.readFile(location.fileURL) {
                content = read
                contentCache[location.fileURL] = read
            } else {
                continue
            }

            let lines = content.components(separatedBy: "\n")
            let lineIndex = location.line - 1
            guard lineIndex >= 0, lineIndex < lines.count else { continue }

            results.append(SearchResult(
                filePath:    location.fileURL.path,
                lineNumber:  location.line,
                lineContent: lines[lineIndex],
                matchRange:  NSRange(location: max(0, location.character - 1), length: 0)
            ))
        }

        results.sort {
            $0.filePath == $1.filePath ? $0.lineNumber < $1.lineNumber : $0.filePath < $1.filePath
        }
        referencesResults = results
        statusMessage = "\(results.count) reference\(results.count == 1 ? "" : "s") found"
    }

    /// The identifier touching (0-based) `line`/`character` in `content`, or
    /// `nil` when `content` is missing or the position isn't inside a word —
    /// used only to label the References panel's header. Delegates the
    /// actual word-boundary scan to the shared top-level
    /// `identifierWordRange`/`isIdentifierChar` (also used by
    /// `EditorView.Coordinator`) so "what counts as one word" can't drift
    /// between the editor and this panel-labeling code.
    private static func identifier(inLine content: String?, line: Int, character: Int) -> String? {
        guard let content else { return nil }
        let lines = content.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { return nil }
        let ns = lines[line] as NSString
        guard let range = identifierWordRange(in: ns, around: character) else { return nil }
        return ns.substring(with: range)
    }

    /// Opens `location.fileURL` (activating its tab if already open, else
    /// reading it into a new one) and jumps the editor's caret to
    /// `location.line`/`location.character` once its content is loaded —
    /// used by References panel row clicks. Bridges into the editor from
    /// outside its own view hierarchy via `pendingNavigationTarget`, which
    /// `EditorView`/`Coordinator.consumePendingNavigation` consumes. Wrapped
    /// in a fresh `NavigationRequest` (unique `id` per call) rather than the
    /// bare `DefinitionLocation` so navigating to the *same* location twice
    /// in a row (e.g. clicking the same reference again) still produces a
    /// distinct request the Coordinator recognizes as new — see
    /// `NavigationRequest`'s doc comment in `SharedTypes.swift`.
    func navigateTo(_ location: DefinitionLocation) async {
        pendingNavigationTarget = NavigationRequest(id: UUID(), location: location)
        await openFile(location.fileURL)
    }

    /// Maps a References-panel `SearchResult` row back to the
    /// `DefinitionLocation` it came from (recovering the column from
    /// `matchRange.location`, the same field `findReferences` populated it
    /// with) and navigates to it.
    func navigateToReference(_ result: SearchResult) async {
        await navigateTo(DefinitionLocation(
            fileURL: URL(fileURLWithPath: result.filePath),
            line: result.lineNumber,
            character: result.matchRange.location + 1
        ))
    }

    // MARK: - Rename Symbol

    /// Requests `textDocument/rename` at (0-based) `line`/`character` in
    /// `fileURL`, renaming the symbol there to `newName`, and applies the
    /// resulting workspace edit — reusing `applyLSPTextEdits`, the same pure
    /// offset-conversion function `formattedContent(for:)` uses for
    /// format-on-save, so that logic isn't duplicated here.
    ///
    /// Safety for files with unsaved edits: the LSP server's view of an
    /// *open* file is whatever content `didOpen`/`didChange` last sent it —
    /// the tab's in-memory content, not necessarily what's on disk — so an
    /// open file's edits are always applied there, dirty or not. A **clean**
    /// open tab is then written straight to disk (nothing to lose). A
    /// **dirty** open tab is deliberately *not* written to disk: the rename
    /// is folded into the in-memory buffer alongside the user's unsaved
    /// edits and the tab is left dirty, so a normal Cmd+S persists both
    /// together instead of the rename silently overwriting unsaved work (or
    /// the rename being dropped to avoid that). Files not open in any tab
    /// are read from and written straight back to disk.
    ///
    /// Safety against concurrent edits: `textDocument/rename` is a
    /// round-trip to a subprocess and can take a noticeable moment; nothing
    /// blocks the user from typing into an affected tab while it's in
    /// flight (only the preceding rename-prompt alert blocks, and it's
    /// already dismissed by the time this `await` starts). The server's
    /// edit offsets are computed against whatever content it last saw via
    /// `didOpen`/`didChange` — applying them to a buffer that has since
    /// changed would silently misplace or corrupt text. Each open tab's
    /// content is snapshotted *before* the request goes out, and any tab
    /// whose content no longer matches its snapshot when the response comes
    /// back has its edits skipped (reported in the status message) rather
    /// than applied against stale offsets.
    func renameSymbol(fileURL: URL, line: Int, character: Int, newName: String) async {
        let contentSnapshot: [URL: String] = Dictionary(
            uniqueKeysWithValues: openTabs.compactMap { tab in
                tab.fileURL.map { ($0, tab.content) }
            }
        )

        guard let edits = try? await lspManager.rename(
            fileURL: fileURL, line: line, character: character, newName: newName
        ), !edits.isEmpty else {
            statusMessage = "Rename failed: language server returned no changes"
            return
        }

        var writtenCount = 0
        var bufferOnlyCount = 0
        var staleSkippedCount = 0

        for (url, textEdits) in edits where !textEdits.isEmpty {
            if let index = openTabs.firstIndex(where: { $0.fileURL == url }) {
                guard openTabs[index].content == contentSnapshot[url] else {
                    // The buffer changed while the rename request was in
                    // flight — the server's edit offsets no longer line up
                    // with this content, so applying them now would corrupt
                    // rather than rename.
                    staleSkippedCount += 1
                    continue
                }

                let renamed = applyLSPTextEdits(textEdits, to: openTabs[index].content)
                openTabs[index].content = renamed
                // The server itself dictated this content (it's the rename
                // response), but it still needs to be told the document
                // changed so its own subsequent requests (diagnostics,
                // completions, another rename) see the renamed text —
                // exactly what `updateTabContent` does for every other edit.
                await lspManager.didChange(fileURL: url, content: renamed)

                if openTabs[index].isDirty {
                    bufferOnlyCount += 1
                } else {
                    do {
                        try await fileService.writeFile(url, content: renamed)
                        writtenCount += 1
                    } catch {
                        // Couldn't persist — keep the rename visible in the
                        // buffer rather than silently dropping it, and mark
                        // the tab dirty so the failure is obvious.
                        openTabs[index].isDirty = true
                        bufferOnlyCount += 1
                    }
                }
            } else if let original = try? await fileService.readFile(url) {
                let renamed = applyLSPTextEdits(textEdits, to: original)
                do {
                    try await fileService.writeFile(url, content: renamed)
                    writtenCount += 1
                } catch {
                    continue
                }
            }
        }

        if writtenCount > 0 { await refreshGitStatus() }

        var message = "Renamed to \"\(newName)\""
        if writtenCount > 0 {
            message += " — \(writtenCount) file\(writtenCount == 1 ? "" : "s") saved"
        }
        if bufferOnlyCount > 0 {
            message += (writtenCount > 0 ? ", " : " — ")
                + "\(bufferOnlyCount) applied to unsaved buffer\(bufferOnlyCount == 1 ? "" : "s") (save to persist)"
        }
        if staleSkippedCount > 0 {
            message += " — \(staleSkippedCount) file\(staleSkippedCount == 1 ? "" : "s") skipped (edited during rename; re-run if still needed)"
        }
        statusMessage = message
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
        guard isFileOpen(url) else { return }
        let content = try? await fileService.readFile(url)
        updateTabs(withFileURL: url) { tab in
            if tab.isDirty {
                tab.externallyModified = true
            } else if let content {
                tab.content = content
                tab.isDirty = false
                tab.externallyModified = false
            }
        }
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
        guard isFileOpen(url) else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            await fileWatchService.watchFile(url)
            await handleExternalFileChange(url)
        } else {
            markFileOrphaned(url)
        }
    }

    /// A truly-deleted file's tab(s): force them dirty rather than let a
    /// later save silently fail — the status bar message is the signal for
    /// this pass; the banner is reserved for the "changed while dirty" case
    /// above. Caller (`handleExternalFileRemoval`) already confirmed the
    /// file is open somewhere, so the status message is always relevant.
    private func markFileOrphaned(_ url: URL) {
        updateTabs(withFileURL: url) { tab in tab.isDirty = true }
        statusMessage = "\(url.lastPathComponent) was deleted on disk — save to recreate it."
    }

    /// "Reload" banner action: discards local edits and reloads the tab's
    /// content from disk (whichever group holds it).
    func reloadTabFromDisk(_ id: UUID) async {
        guard let side = side(ofTab: id) else { return }
        var groupTabs = tabs(in: side)
        guard
            let index = groupTabs.firstIndex(where: { $0.id == id }),
            let url = groupTabs[index].fileURL,
            let content = try? await fileService.readFile(url)
        else { return }
        groupTabs[index].content = content
        groupTabs[index].isDirty = false
        groupTabs[index].externallyModified = false
        setTabs(groupTabs, in: side)
    }

    /// "Keep My Changes" banner action: dismisses the notice without
    /// touching the buffer — the next save overwrites the on-disk version.
    func keepLocalChanges(_ id: UUID) {
        guard let side = side(ofTab: id) else { return }
        var groupTabs = tabs(in: side)
        guard let index = groupTabs.firstIndex(where: { $0.id == id }) else { return }
        groupTabs[index].externallyModified = false
        setTabs(groupTabs, in: side)
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
            openNewTab(in: focusedGroup)
        case .closeTab:
            if let id = focusedTab?.id { closeTab(id) }
        case .splitEditorRight:
            splitEditorRight()
        case .toggleZenMode:
            isZenMode.toggle()
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
        case .goToSymbol:
            presentQuickOpen(prefill: "@")
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
        case .findReferences:
            postEditorCommand(.findReferences)
        case .renameSymbol:
            postEditorCommand(.renameSymbol)
        case .moveLineUp:
            postEditorCommand(.moveLineUp)
        case .moveLineDown:
            postEditorCommand(.moveLineDown)
        case .copyLineUp:
            postEditorCommand(.copyLineUp)
        case .copyLineDown:
            postEditorCommand(.copyLineDown)
        case .deleteLine:
            postEditorCommand(.deleteLine)
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

    /// Saves every open tab (in EITHER group) that has unsaved changes,
    /// formatting each one first (per-tab) when `editorFormatOnSave` is on —
    /// same formatters as `saveActiveTab()`. Unlike the other "current file"
    /// commands, Save All isn't group-scoped — there's no per-group "save
    /// all" in VS Code either, it just means "save everything open."
    func saveAllTabs() async {
        for side: EditorGroupSide in [.primary, .secondary] {
            for tab in tabs(in: side) where tab.isDirty {
                guard let url = tab.fileURL else { continue }

                var contentToSave = tab.content
                if let formatted = await formattedContent(for: tab) {
                    contentToSave = formatted
                    var groupTabs = tabs(in: side)
                    if let i = groupTabs.firstIndex(where: { $0.id == tab.id }) {
                        groupTabs[i].content = formatted
                        setTabs(groupTabs, in: side)
                    }
                }

                do {
                    try await fileService.writeFile(url, content: contentToSave)
                    var groupTabs = tabs(in: side)
                    if let i = groupTabs.firstIndex(where: { $0.id == tab.id }) {
                        groupTabs[i].isDirty = false
                        groupTabs[i].externallyModified = false
                        setTabs(groupTabs, in: side)
                        await refreshGitLineChanges(for: groupTabs[i])
                    }
                } catch {
                    statusMessage = "Error saving \(url.lastPathComponent): \(error.localizedDescription)"
                }
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

    /// Opens a new blank ("Untitled") tab in `side` and makes it that
    /// group's active tab (and the focused one) — the tab bar's "+" button,
    /// per-pane, and Cmd+N (routed to whichever group is currently focused).
    func openNewTab(in side: EditorGroupSide) {
        let tab = TabModel.untitled()
        var groupTabs = tabs(in: side)
        groupTabs.append(tab)
        setTabs(groupTabs, in: side)
        setActiveTabId(tab.id, in: side)
        focusedGroup = side
        if side == .primary {
            Task { await self.persistSession() }
        }
    }

    // MARK: - Terminal Sessions

    /// Opens a new terminal tab (the "+" button in `TerminalTabStripView`)
    /// and makes it active. Titled after the detected `$SHELL` — just the
    /// shell name ("zsh") for the first session created this launch, numbered
    /// ("zsh 2", "zsh 3", …) after that.
    func newTerminalSession() {
        terminalSessionSequence += 1
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let title = terminalSessionSequence == 1 ? shellName : "\(shellName) \(terminalSessionSequence)"
        let session = TerminalSession(title: title, shell: shellPath)
        terminalSessions.append(session)
        activeTerminalSessionId = session.id
    }

    /// Closes the terminal session with the given ID, activating an adjacent
    /// session if it was the active one — mirrors `closeTab`'s
    /// adjacent-selection logic via the pure `TerminalSession.nextActiveId`.
    /// Closing the last remaining session leaves `terminalSessions` empty and
    /// `activeTerminalSessionId` nil; `TerminalPanelView` shows a "New
    /// Terminal" empty state in that case, the same way the editor shows the
    /// Welcome screen with zero open tabs.
    func closeTerminalSession(_ id: UUID) {
        guard let index = terminalSessions.firstIndex(where: { $0.id == id }) else { return }
        let newActiveId = TerminalSession.nextActiveId(
            afterClosing: id,
            in: terminalSessions,
            previousActiveId: activeTerminalSessionId
        )
        terminalSessions.remove(at: index)
        activeTerminalSessionId = newActiveId
    }

    /// Activates the terminal session with the given ID (a tab-strip click).
    func activateTerminalSession(_ id: UUID) {
        guard terminalSessions.contains(where: { $0.id == id }) else { return }
        activeTerminalSessionId = id
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

    /// Cycles the FOCUSED group's active tab — Next/Previous Editor act on
    /// "the current" tab strip, same as VS Code's per-group tab cycling.
    private func cycleTab(forward: Bool) {
        let side = focusedGroup
        let groupTabs = tabs(in: side)
        guard !groupTabs.isEmpty else { return }
        let current  = groupTabs.firstIndex(where: { $0.id == activeTabId(in: side) }) ?? 0
        let next     = forward
            ? (current + 1) % groupTabs.count
            : (current - 1 + groupTabs.count) % groupTabs.count
        setActiveTabId(groupTabs[next].id, in: side)
        if side == .primary {
            Task { await self.persistSession() }
        }
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
