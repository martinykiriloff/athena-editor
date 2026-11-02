// AppState+Folding.swift
// Athena — records which regions are folded in each tab so they survive tab switches and relaunch.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    /// Stores a tab's folded header lines. Unlike `setCursorPosition` this
    /// does not move group focus, since folds can change from a background
    /// refresh.
    func setFoldedLines(tabId: UUID, in side: EditorGroupSide, lines: [Int]) {
        var groupTabs = tabs(in: side)
        guard let index = groupTabs.firstIndex(where: { $0.id == tabId }),
              groupTabs[index].foldedLines != lines else { return }
        groupTabs[index].foldedLines = lines
        setTabs(groupTabs, in: side)
    }
}
