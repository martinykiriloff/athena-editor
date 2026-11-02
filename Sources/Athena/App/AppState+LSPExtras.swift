// AppState+LSPExtras.swift
// Athena — organize imports, fix-all on save, hierarchy panel, code lens activation,
// file watch/rename forwarding to language servers.
// Swift 6, strict concurrency.

import Foundation

/// What clicking a code lens should do. Pure so it can be unit-tested.
enum CodeLensAction: Equatable {
    case showReferences
    case execute

    /// Servers implement some lens commands on the client (`editor.action.showReferences`,
    /// `rust-analyzer.showReferences`); sending those to `workspace/executeCommand` would fail.
    static func classify(command: String) -> CodeLensAction {
        let lower = command.lowercased()
        return lower.contains("showreferences") || lower.hasSuffix(".references") || lower.contains("findreferences")
            ? .showReferences : .execute
    }
}

@MainActor
extension AppState {

    // MARK: - Organize imports

    /// Runs the server's `source.organizeImports` action on the focused tab.
    func organizeImports() async {
        guard let tab = focusedTab, let url = tab.fileURL, tab.language != .image else { return }
        let actions = await lspManager.sourceActions(fileURL: url, kind: "source.organizeImports", content: tab.content)
        guard let action = actions.first else {
            statusMessage = "No organize imports action available"
            return
        }
        await performCodeAction(action)
    }

    // MARK: - Fix all on save

    /// The tab's content after the server's `source.fixAll` edits, or nil when
    /// the setting is off, there is nothing to fix, or the server has no edits
    /// for this file. The server is told about the new text so a following
    /// format-on-save request addresses the fixed document. Command-only
    /// actions and edits to other files are not applied here.
    func contentAfterFixAll(for tab: TabModel) async -> String? {
        guard editorFixAllOnSave, let url = tab.fileURL, tab.language != .image, !isLargeFile(tab) else { return nil }
        let actions = await lspManager.sourceActions(fileURL: url, kind: "source.fixAll", content: tab.content)
        let edits = actions.flatMap { $0.edits[url] ?? [] }
        guard !edits.isEmpty else { return nil }
        let fixed = applyLSPTextEdits(edits, to: tab.content)
        guard fixed != tab.content else { return nil }
        await lspManager.didChange(fileURL: url, content: fixed)
        return fixed
    }

    // MARK: - Watched files and file operations

    /// Tells running servers about an on-disk change (`workspace/didChangeWatchedFiles`).
    func forwardWatchedFile(_ url: URL, type: Int) {
        Task { await self.lspManager.didChangeWatchedFiles([(url: url, type: type)]) }
    }

    /// Asks servers for import updates before `old` moves to `new`
    /// (`workspace/willRenameFiles`) and applies them through the same path as
    /// rename/quick fix: open tabs are edited in the buffer, other files on disk.
    func applyWillRenameEdits(from old: URL, to new: URL) async {
        let isDirectory = (try? old.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let edits = await lspManager.willRenameFiles([(old: old, new: new, isDirectory: isDirectory)])
        guard !edits.isEmpty else { return }
        if await applyWorkspaceEdit(edits) {
            statusMessage = "Updated imports for \(old.lastPathComponent)"
        }
    }

    /// `workspace/didRenameFiles` plus a created/deleted pair for watchers.
    func notifyDidRename(from old: URL, to new: URL) {
        let isDirectory = (try? new.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        Task {
            await self.lspManager.didRenameFiles([(old: old, new: new, isDirectory: isDirectory)])
            await self.lspManager.didChangeWatchedFiles([(url: old, type: 3), (url: new, type: 1)])
        }
    }

    // MARK: - Code lens

    /// Click on a code lens: client-side "show references" commands open the
    /// References panel, everything else runs on the server.
    func activateCodeLens(_ lens: CodeLens, fileURL: URL) async {
        guard let command = lens.command else { return }
        switch CodeLensAction.classify(command: command.command) {
        case .showReferences:
            await findReferences(fileURL: fileURL, line: lens.line, character: lens.character)
        case .execute:
            await lspManager.runCodeLens(lens, fileURL: fileURL)
        }
    }

    // MARK: - Call / type hierarchy

    /// Opens the Hierarchy panel rooted at the focused editor's caret.
    func showHierarchy(types: Bool) async {
        guard let tab = focusedTab, let url = tab.fileURL else { return }
        isLoadingHierarchy = true
        defer { isLoadingHierarchy = false }
        showBottomPanel = true
        activeBottomPanel = .hierarchy
        hierarchyRoots = []
        hierarchyChildren = [:]
        hierarchyDirection = types ? .supertypes : .incomingCalls
        let roots = await lspManager.prepareHierarchy(
            fileURL: url, line: max(tab.cursorLine - 1, 0), character: max(tab.cursorColumn - 1, 0), types: types
        )
        hierarchyRoots = roots
        if roots.isEmpty {
            statusMessage = types ? "No type hierarchy available here" : "No call hierarchy available here"
        } else {
            await loadChildren(of: roots[0])
        }
    }

    /// Switches between incoming/outgoing calls (or super/subtypes) for the current roots.
    func setHierarchyDirection(_ direction: HierarchyDirection) async {
        hierarchyDirection = direction
        hierarchyChildren = [:]
        for root in hierarchyRoots { await loadChildren(of: root) }
    }

    /// Fetches `item`'s children in the current direction (cached by item id).
    func loadChildren(of item: HierarchyItem) async {
        guard hierarchyChildren[item.id] == nil else { return }
        let direction = hierarchyDirection
        let children = await lspManager.hierarchy(of: item, direction: direction)
        guard direction == hierarchyDirection else { return }
        hierarchyChildren[item.id] = children
    }

    /// Jumps the editor to a hierarchy item.
    func openHierarchyItem(_ item: HierarchyItem) async {
        await navigateTo(DefinitionLocation(fileURL: item.fileURL, line: item.line + 1, character: item.character + 1))
    }
}
