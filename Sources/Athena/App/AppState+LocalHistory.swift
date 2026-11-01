// AppState+LocalHistory.swift
// Athena — recording, browsing and restoring Local History snapshots.
// Swift 6, strict concurrency.

import Foundation

extension AppState {

    // MARK: - Recording

    /// Called after a successful save. Failures are non-fatal: history is a
    /// convenience and must never block or fail a save.
    func recordLocalHistory(of url: URL, content: String) async {
        _ = try? await localHistoryService.recordSnapshot(of: url, content: content)
    }

    // MARK: - Presentation

    func showLocalHistory() async {
        guard let tab = focusedTab, tab.language != .image, let url = tab.fileURL else {
            statusMessage = "Local History: no file open"
            return
        }
        localHistory = LocalHistoryState(isPresented: true, fileURL: url, tabID: tab.id)
        let snapshots = await localHistoryService.snapshots(for: url)
        guard localHistory.isPresented, localHistory.fileURL == url else { return }
        localHistory.snapshots = snapshots
        if let first = snapshots.first { await selectLocalHistorySnapshot(first.id) }
    }

    func closeLocalHistory() {
        localHistory = LocalHistoryState()
    }

    // MARK: - Selection

    func selectLocalHistorySnapshot(_ id: String) async {
        guard let url = localHistory.fileURL,
              let snapshot = localHistory.snapshots.first(where: { $0.id == id })
        else { return }
        localHistory.selectedID = id
        localHistory.errorMessage = nil
        do {
            let old = try await localHistoryService.content(of: snapshot, for: url)
            guard localHistory.selectedID == id else { return }
            localHistory.diff = LineDiffBuilder.diff(old: old, new: currentLocalHistoryContent())
        } catch {
            guard localHistory.selectedID == id else { return }
            localHistory.diff = .empty
            localHistory.errorMessage = "Unable to read this snapshot."
        }
    }

    // MARK: - Restore

    /// Replaces the tab's buffer with the selected snapshot (left unsaved, so
    /// the user can review it). The pre-restore buffer is snapshotted first so
    /// the restore itself is undoable from history.
    func restoreSelectedLocalHistorySnapshot() async {
        guard let url = localHistory.fileURL,
              let tabID = localHistory.tabID,
              let id = localHistory.selectedID,
              let snapshot = localHistory.snapshots.first(where: { $0.id == id })
        else { return }
        do {
            let content = try await localHistoryService.content(of: snapshot, for: url)
            await recordLocalHistory(of: url, content: currentLocalHistoryContent())
            updateTabContent(tabID, content: content)
            statusMessage = "Restored \(url.lastPathComponent) from Local History (unsaved)"
            closeLocalHistory()
        } catch {
            localHistory.errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private helper

    private func currentLocalHistoryContent() -> String {
        guard let tabID = localHistory.tabID else { return "" }
        for side: EditorGroupSide in [.primary, .secondary] {
            if let tab = tabs(in: side).first(where: { $0.id == tabID }) { return tab.content }
        }
        return ""
    }
}
