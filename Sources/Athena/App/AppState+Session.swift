// AppState+Session.swift
// Athena — hot exit: snapshot and restore of workspace, tabs, split group and unsaved buffers.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    // MARK: - Snapshot

    /// Captures the current editor layout. Dirty tabs carry their buffer and
    /// the file's on-disk stamp so restore can detect outside changes.
    func makeSessionSnapshot() -> SessionSnapshot {
        func state(_ tab: TabModel) -> SessionTabState {
            var s = SessionTabState(
                path: tab.fileURL?.path,
                title: tab.title,
                cursorLine: tab.cursorLine,
                cursorColumn: tab.cursorColumn
            )
            s.isMarkdownPreview = tab.isMarkdownPreview
            s.foldedLines = tab.foldedLines.isEmpty ? nil : tab.foldedLines
            if tab.isDirty {
                s.unsavedContent = tab.content
                s.externallyModified = tab.externallyModified
                if let url = tab.fileURL { s.diskStamp = SessionStore.diskStamp(for: url) }
            }
            return s
        }
        // Untitled tabs only matter when they hold text.
        func keep(_ tab: TabModel) -> Bool { tab.fileURL != nil || tab.isDirty }

        var snap = SessionSnapshot()
        snap.workspacePath = workspace?.rootURL.path
        let primary = openTabs.filter(keep)
        snap.primaryTabs = primary.map(state)
        snap.primaryActiveIndex = primary.firstIndex { $0.id == activeTabId }
        if let group = secondaryGroup {
            let secondary = group.tabs.filter(keep)
            if !secondary.isEmpty {
                snap.secondaryTabs = secondary.map(state)
                snap.secondaryActiveIndex = secondary.firstIndex { $0.id == group.activeTabId }
                snap.secondaryFocused = focusedGroup == .secondary
            }
        }
        return snap
    }

    /// Writes the snapshot synchronously. Used on app termination, where
    /// there is no time to await anything.
    func saveSessionSnapshotSync() {
        guard sessionAutosaveEnabled else { return }
        try? SessionStore.writeSync(makeSessionSnapshot(), to: sessionStore.fileURL)
    }

    /// Starts the periodic snapshot task; only writes when something changed.
    /// Called once the launch restore finished, so a half-restored (empty)
    /// state can never overwrite the saved session.
    func startSessionAutosave() {
        sessionAutosaveEnabled = true
        sessionAutosaveTask?.cancel()
        let store = sessionStore
        sessionAutosaveTask = Task { [weak self] in
            var last: SessionSnapshot?
            let clock = ContinuousClock()
            while !Task.isCancelled {
                try? await clock.sleep(until: clock.now.advanced(by: .seconds(5)))
                guard !Task.isCancelled, let self else { return }
                let snap = self.makeSessionSnapshot()
                if snap != last {
                    try? await store.save(snap)
                    last = snap
                }
            }
        }
    }

    // MARK: - Restore

    /// Launch entry point: loads the saved session and opens its workspace
    /// (the tabs are applied from `restoreSession(for:)`), or applies it
    /// directly when it had no workspace. Starts autosave afterwards in
    /// every case.
    func restoreHotExitSession() async {
        defer { startSessionAutosave() }
        guard let snap = await sessionStore.load(), !snap.isEmpty else {
            await restoreLastWorkspace()
            return
        }
        guard let path = snap.workspacePath else {
            await applySessionSnapshot(snap)
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            pendingSessionSnapshot = snap
            await openWorkspace(URL(fileURLWithPath: path))
            pendingSessionSnapshot = nil
        } else {
            await restoreLastWorkspace()
        }
    }

    /// Rebuilds both groups from `snap`. Never writes to disk: a restored
    /// dirty buffer stays dirty. If the file changed on disk after the
    /// snapshot (or is gone) the tab is flagged `externallyModified`, which
    /// shows the Reload / Keep My Changes banner.
    func applySessionSnapshot(_ snap: SessionSnapshot) async {
        var changed: [String] = []
        let primary = await restoreTabs(snap.primaryTabs, activeIndex: snap.primaryActiveIndex, changed: &changed)
        setTabs(primary.tabs, in: .primary)
        activeTabId = primary.active

        if let states = snap.secondaryTabs, !states.isEmpty {
            let secondary = await restoreTabs(states, activeIndex: snap.secondaryActiveIndex, changed: &changed)
            if !secondary.tabs.isEmpty {
                var group = EditorGroup()
                group.tabs = secondary.tabs
                group.activeTabId = secondary.active
                secondaryGroup = group
                focusedGroup = snap.secondaryFocused ? .secondary : .primary
            }
        }

        // Re-register restored files with the file watcher and language servers.
        for tab in openTabs + (secondaryGroup?.tabs ?? []) {
            guard let url = tab.fileURL else { continue }
            await fileWatchService.watchFile(url)
            guard tab.language != .image, let workspace else { continue }
            let content = tab.content
            let language = tab.language
            Task {
                try? await self.lspManager.startServer(for: language, workspaceURL: workspace.rootURL)
                await self.lspManager.didOpen(fileURL: url, content: content)
            }
        }

        if !changed.isEmpty {
            statusMessage = changed.count == 1
                ? "\(changed[0]) changed on disk since your unsaved edits were saved. Review before saving."
                : "\(changed.count) files changed on disk since your unsaved edits were saved. Review before saving."
        }
    }

    private func restoreTabs(
        _ states: [SessionTabState],
        activeIndex: Int?,
        changed: inout [String]
    ) async -> (tabs: [TabModel], active: UUID?) {
        var tabs: [TabModel] = []
        var activeId: UUID?
        for (i, st) in states.enumerated() {
            guard let tab = await restoreTab(st, changed: &changed) else { continue }
            // One tab per file within a group.
            if let url = tab.fileURL, tabs.contains(where: { $0.fileURL == url }) { continue }
            tabs.append(tab)
            if i == activeIndex { activeId = tab.id }
        }
        return (tabs, activeId ?? tabs.first?.id)
    }

    /// Builds one tab, or `nil` when there is nothing to restore (file gone
    /// and no unsaved edits, or unreadable).
    private func restoreTab(_ st: SessionTabState, changed: inout [String]) async -> TabModel? {
        var tab: TabModel
        if let path = st.path {
            let url = URL(fileURLWithPath: path)
            let language = Language.detect(from: url)
            tab = TabModel(title: url.lastPathComponent)
            tab.fileURL = url
            tab.language = language
            let exists = FileManager.default.fileExists(atPath: path)

            if let unsaved = st.unsavedContent {
                tab.content = unsaved
                tab.isDirty = true
                let now = exists ? SessionStore.diskStamp(for: url) : nil
                let diskChanged = !exists || st.diskStamp == nil || now != st.diskStamp
                if diskChanged || st.externallyModified {
                    tab.externallyModified = true
                    changed.append(url.lastPathComponent)
                }
            } else {
                guard exists else { return nil }
                if language != .image {
                    guard let content = try? await fileService.readFile(url) else { return nil }
                    tab.content = content
                }
            }
        } else {
            guard let unsaved = st.unsavedContent else { return nil }
            tab = TabModel(title: st.title)
            tab.content = unsaved
            tab.isDirty = true
        }
        tab.cursorLine = st.cursorLine
        tab.cursorColumn = st.cursorColumn
        tab.isMarkdownPreview = st.isMarkdownPreview
        tab.foldedLines = st.foldedLines ?? []
        return tab
    }
}
