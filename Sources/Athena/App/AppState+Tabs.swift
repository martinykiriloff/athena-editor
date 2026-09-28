// AppState+Tabs.swift
// Athena — Reopen Closed Editor (⇧⌘T) and preview tabs.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    // MARK: - Reopen closed editor

    /// Pushes a closed tab onto the reopen stack. A file closed again moves
    /// to the top instead of appearing twice.
    func rememberClosedTab(_ closed: ClosedTab) {
        recentlyClosedTabs.removeAll { $0.fileURL == closed.fileURL }
        recentlyClosedTabs.append(closed)
        if recentlyClosedTabs.count > Self.closedTabLimit {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.closedTabLimit)
        }
    }

    /// Reopens the most recently closed file at its old caret position,
    /// skipping files that were deleted or are open again already.
    func reopenClosedTab() async {
        while let closed = recentlyClosedTabs.popLast() {
            guard FileManager.default.fileExists(atPath: closed.fileURL.path),
                  side(ofOpenFile: closed.fileURL) == nil
            else { continue }
            await navigateTo(DefinitionLocation(
                fileURL: closed.fileURL,
                line: closed.line,
                character: closed.column
            ))
            return
        }
        statusMessage = "No closed editors to reopen"
    }

    // MARK: - Preview tabs

    /// Adds a newly opened tab to `side` and activates it. A preview tab
    /// takes the place of the group's existing clean preview tab, which is
    /// closed, as in VS Code; anything else is appended.
    func placeNewTab(_ tab: TabModel, in side: EditorGroupSide) {
        var index: Int?
        if tab.isPreview,
           let old = tabs(in: side).firstIndex(where: { $0.isPreview && !$0.isDirty }) {
            index = old
            closeTab(tabs(in: side)[old].id)
        }
        var groupTabs = tabs(in: side)
        groupTabs.insert(tab, at: min(index ?? groupTabs.count, groupTabs.count))
        setTabs(groupTabs, in: side)
        setActiveTabId(tab.id, in: side)
    }

    /// Makes a preview tab permanent. A no-op for any other tab.
    func pinTab(_ id: UUID) {
        guard let side = side(ofTab: id) else { return }
        var groupTabs = tabs(in: side)
        guard let index = groupTabs.firstIndex(where: { $0.id == id }), groupTabs[index].isPreview else { return }
        groupTabs[index].isPreview = false
        setTabs(groupTabs, in: side)
    }

    /// Explorer double click: keeps the file's tab open. Synchronous, so it
    /// also covers the double click landing while the first click's preview
    /// open is still reading the file — that open then comes out permanent.
    func keepOpen(_ url: URL) {
        let matching = [EditorGroupSide.primary, .secondary]
            .flatMap { tabs(in: $0) }
            .filter { $0.fileURL == url }
        if matching.isEmpty {
            pendingPins.insert(url)
        } else {
            matching.forEach { pinTab($0.id) }
        }
    }
}
