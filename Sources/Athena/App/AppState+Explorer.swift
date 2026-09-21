// AppState+Explorer.swift
// Athena — file tree (explorer) actions behind the sidebar's context menu.
// Swift 6, strict concurrency.

@preconcurrency import AppKit

@MainActor
extension AppState {

    // MARK: - Tree refresh

    /// Rebuilds `fileTree` from disk, keeping every folder that was expanded
    /// expanded (a plain rebuild comes back fully collapsed), plus the
    /// folders in `extra` and their ancestors — used to reveal a freshly
    /// created or pasted item.
    func refreshFileTree(expanding extra: [URL] = []) async {
        guard let workspace else { return }
        var expanded = Self.expandedPaths(in: fileTree)
        let rootPath = Self.canonicalPath(workspace.rootURL)
        for url in extra {
            var dir = url
            while Self.canonicalPath(dir).hasPrefix(rootPath + "/") {
                expanded.insert(Self.canonicalPath(dir))
                dir = dir.deletingLastPathComponent()
            }
        }
        do {
            var tree = try await fileService.buildFileTree(workspace.rootURL)
            Self.applyExpansion(expanded, to: &tree)
            fileTree = tree
        } catch {
            statusMessage = "Error refreshing file tree: \(error.localizedDescription)"
        }
    }

    nonisolated static func expandedPaths(in nodes: [FileNode]) -> Set<String> {
        var result: Set<String> = []
        for node in nodes where node.isDirectory && node.isExpanded {
            result.insert(canonicalPath(node.url))
            if let children = node.children {
                result.formUnion(expandedPaths(in: children))
            }
        }
        return result
    }

    nonisolated static func applyExpansion(_ expanded: Set<String>, to nodes: inout [FileNode]) {
        for i in nodes.indices where nodes[i].isDirectory {
            nodes[i].isExpanded = expanded.contains(canonicalPath(nodes[i].url))
            if nodes[i].children != nil {
                applyExpansion(expanded, to: &nodes[i].children!)
            }
        }
    }

    // MARK: - Create / Rename / Delete / Duplicate

    /// "New File…" — `name` may contain `/` to create intermediate folders
    /// ("components/Button.tsx"), like VS Code. Opens the new file.
    func createExplorerFile(named name: String, in directory: URL) async {
        guard let target = Self.childURL(named: name, in: directory) else {
            statusMessage = "Invalid file name: \(name)"
            return
        }
        do {
            try await fileService.createDirectory(at: target.deletingLastPathComponent())
            try await fileService.createFile(at: target)
            await refreshFileTree(expanding: [target.deletingLastPathComponent()])
            await openFile(target)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createExplorerFolder(named name: String, in directory: URL) async {
        guard let target = Self.childURL(named: name, in: directory) else {
            statusMessage = "Invalid folder name: \(name)"
            return
        }
        guard await !fileService.itemExists(target) else {
            statusMessage = "\"\(target.lastPathComponent)\" already exists"
            return
        }
        do {
            try await fileService.createDirectory(at: target)
            await refreshFileTree(expanding: [target])
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameExplorerItem(_ url: URL, to newName: String) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            statusMessage = "Invalid name: \(newName)"
            return
        }
        guard name != url.lastPathComponent else { return }
        do {
            let newURL = try await fileService.rename(url, to: name)
            retargetTabs(from: url, to: newURL)
            await refreshFileTree()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Moves `url` to the Trash. Clean tabs for the item (or anything under
    /// a trashed folder) close; dirty ones stay open so no edits are lost —
    /// the file watcher then flags them as deleted on disk.
    func trashExplorerItem(_ url: URL) async {
        do {
            try await fileService.trash(url)
            let doomed = (openTabs + (secondaryGroup?.tabs ?? []))
                .filter { tab in
                    guard let fileURL = tab.fileURL, !tab.isDirty else { return false }
                    return Self.isItem(fileURL, within: url)
                }
                .map(\.id)
            for id in doomed { closeTab(id) }
            if let selected = compareSelectionURL, Self.isItem(selected, within: url) {
                compareSelectionURL = nil
            }
            await refreshFileTree()
            statusMessage = "Moved \(url.lastPathComponent) to Trash"
        } catch {
            statusMessage = "Couldn't delete \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func duplicateExplorerItem(_ url: URL) async {
        let destination = await fileService.uniqueDestination(for: url, in: url.deletingLastPathComponent())
        do {
            try await fileService.copyItem(from: url, to: destination)
            await refreshFileTree()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Cut / Copy / Paste

    /// Puts the items on the general pasteboard as file URLs, so they paste
    /// into Finder too.
    func copyExplorerItems(_ urls: [URL]) {
        cutFileURLs = []
        writeFileURLsToPasteboard(urls)
        statusMessage = urls.count == 1 ? "Copied \(urls[0].lastPathComponent)" : "Copied \(urls.count) items"
    }

    func cutExplorerItems(_ urls: [URL]) {
        writeFileURLsToPasteboard(urls)
        cutFileURLs = urls
        statusMessage = urls.count == 1 ? "Cut \(urls[0].lastPathComponent)" : "Cut \(urls.count) items"
    }

    /// Pastes the pasteboard's file URLs (from Athena or Finder) into
    /// `directory`. A paste of exactly what was last cut moves it; anything
    /// else copies, taking a "name copy" name when the target is taken.
    func pasteExplorerItems(into directory: URL) async {
        let pasteboard = NSPasteboard.general
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        guard !urls.isEmpty else {
            statusMessage = "Nothing to paste"
            return
        }

        // Compare paths, not URLs: the pasteboard hands folders back with a
        // trailing slash.
        let paths = { (urls: [URL]) in Set(urls.map { Self.canonicalPath($0) }) }
        let isMove = !cutFileURLs.isEmpty && paths(cutFileURLs) == paths(urls)
        var failures: [String] = []

        for source in urls {
            // A folder can't go inside itself.
            if Self.isItem(directory, within: source) {
                failures.append("\(source.lastPathComponent): can't paste a folder into itself")
                continue
            }
            do {
                if isMove {
                    guard Self.canonicalPath(source.deletingLastPathComponent()) != Self.canonicalPath(directory) else {
                        continue
                    }
                    let destination = await fileService.uniqueDestination(for: source, in: directory)
                    try await fileService.moveItem(from: source, to: destination)
                    retargetTabs(from: source, to: destination)
                } else {
                    let destination = await fileService.uniqueDestination(for: source, in: directory)
                    try await fileService.copyItem(from: source, to: destination)
                }
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if isMove {
            cutFileURLs = []
            pasteboard.clearContents()
        }
        await refreshFileTree(expanding: [directory])
        statusMessage = failures.isEmpty
            ? "Pasted \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")"
            : "Paste failed — \(failures.joined(separator: "; "))"
    }

    private func writeFileURLsToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    // MARK: - Paths

    func copyPathToPasteboard(_ url: URL) {
        writeStringToPasteboard(url.path)
    }

    func copyRelativePathToPasteboard(_ url: URL) {
        writeStringToPasteboard(workspaceRelativePath(for: url) ?? url.path)
    }

    /// `url`'s path relative to the workspace root, or nil when outside it
    /// (or when `url` is the root itself).
    func workspaceRelativePath(for url: URL) -> String? {
        guard let root = workspace?.rootURL else { return nil }
        let rootPath = Self.canonicalPath(root)
        let path = Self.canonicalPath(url)
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func writeStringToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - Reveal / open

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openWithDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// A new terminal tab starting in `url` (or its folder, for a file).
    func openInIntegratedTerminal(_ url: URL, isDirectory: Bool) {
        let directory = isDirectory ? url : url.deletingLastPathComponent()
        newTerminalSession(in: directory.path)
        activeBottomPanel = .terminal
        showBottomPanel   = true
    }

    // MARK: - Search / Claude / Git integration

    /// "Find in Folder…": scopes the Search panel's include filter to the
    /// folder and switches to it.
    func findInFolder(_ url: URL) {
        searchIncludePrefill = workspaceRelativePath(for: url) ?? ""
        activeSidebarPanel = .search
        showSidebar = true
    }

    func addExplorerItemToClaudeChat(_ url: URL, isDirectory: Bool) {
        addClaudeContext(ClaudeContextRef(url: url, kind: isDirectory ? .folder : .file))
        showClaudePanel = true
    }

    /// The working-tree change git reports for `url`, if any — unstaged or
    /// untracked first (what "Open Changes" should show), then staged.
    func gitChange(for url: URL) -> (change: GitFileChange, staged: Bool)? {
        guard let path = workspaceRelativePath(for: url) else { return nil }
        let working = gitStatus.conflicted + gitStatus.unstaged + gitStatus.untracked
        if let change = working.first(where: { $0.path == path }) { return (change, false) }
        if let change = gitStatus.staged.first(where: { $0.path == path }) { return (change, true) }
        return nil
    }

    func openChanges(for url: URL) async {
        guard let (change, staged) = gitChange(for: url) else {
            statusMessage = "No changes in \(url.lastPathComponent)"
            return
        }
        await openDiffViewer(for: change, staged: staged)
    }

    func showExplorerFileHistory(_ url: URL) async {
        guard let path = workspaceRelativePath(for: url) else { return }
        activeSidebarPanel = .git
        showSidebar = true
        await showFileHistory(path: path)
    }

    // MARK: - Compare

    func selectForCompare(_ url: URL) {
        compareSelectionURL = url
        statusMessage = "Selected \(url.lastPathComponent) for compare"
    }

    /// Diffs `compareSelectionURL` (left) against `url` (right) in the diff
    /// viewer, via `git diff --no-index`.
    func compareWithSelected(_ url: URL) async {
        guard let base = compareSelectionURL, base != url, let workspace else { return }

        diffViewerChange       = GitFileChange(path: workspaceRelativePath(for: url) ?? url.path, status: "M")
        diffViewerCommit       = nil
        diffViewerStaged       = false
        diffViewerParsedDiff   = .empty
        diffViewerErrorMessage = nil
        diffViewerIsLoading    = true
        defer { diffViewerIsLoading = false }

        do {
            let text = try await gitService.diffFiles(base, url, at: workspace.rootURL)
            diffViewerParsedDiff = UnifiedDiffParser.parse(text)
            statusMessage = diffViewerParsedDiff == .empty
                ? "\(base.lastPathComponent) and \(url.lastPathComponent) are identical"
                : "Comparing \(base.lastPathComponent) ↔ \(url.lastPathComponent)"
        } catch {
            diffViewerErrorMessage = "Git error: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// A path form that compares equal across the ways macOS spells the same
    /// location: directory listings return `/private/var/…`, `/private/tmp/…`
    /// while `resolvingSymlinksInPath` (and most user-facing URLs) drop the
    /// `/private` prefix. Pure string work — no disk access per tree node.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for firmlink in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(firmlink) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// True when `item` is `container` itself or lies somewhere beneath it.
    nonisolated static func isItem(_ item: URL, within container: URL) -> Bool {
        let itemPath = canonicalPath(item)
        let containerPath = canonicalPath(container)
        return itemPath == containerPath || itemPath.hasPrefix(containerPath + "/")
    }

    /// `directory/name`, or nil when `name` is empty, absolute, or tries to
    /// climb out with `.`/`..` components.
    nonisolated static func childURL(named name: String, in directory: URL) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let components = trimmed.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return components.reduce(directory) { $0.appendingPathComponent($1) }
    }

    /// Points open tabs at `newURL` after `oldURL` (a file, or a folder
    /// containing them) was renamed or moved.
    private func retargetTabs(from oldURL: URL, to newURL: URL) {
        let oldPath = Self.canonicalPath(oldURL)
        func retarget(_ tabs: inout [TabModel]) {
            for i in tabs.indices {
                guard let fileURL = tabs[i].fileURL, Self.isItem(fileURL, within: oldURL) else { continue }
                let suffix = String(Self.canonicalPath(fileURL).dropFirst(oldPath.count))
                let moved = URL(fileURLWithPath: newURL.standardizedFileURL.path + suffix)
                tabs[i].fileURL = moved
                tabs[i].title = moved.lastPathComponent
                tabs[i].language = Language.detect(from: moved)
                Task { await self.fileWatchService.watchFile(moved) }
            }
        }
        retarget(&openTabs)
        if secondaryGroup != nil { retarget(&secondaryGroup!.tabs) }
        if let selected = compareSelectionURL, Self.isItem(selected, within: oldURL) {
            compareSelectionURL = nil
        }
    }
}
