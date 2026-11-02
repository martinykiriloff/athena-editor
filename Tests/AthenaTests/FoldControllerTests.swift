// FoldControllerTests.swift
// Athena — fold command selection, key actions, and the decoration controller driving a real text view headlessly.
// Swift 6, strict concurrency.

import Testing
import AppKit
import Foundation
@testable import Athena

@Suite("Fold commands")
struct FoldSelectionTests {
    private let ranges = [FoldRange(startLine: 0, endLine: 9), FoldRange(startLine: 1, endLine: 4),
                          FoldRange(startLine: 2, endLine: 3), FoldRange(startLine: 6, endLine: 8)]

    @Test func foldAtCaretPicksInnermostThenFoldsOutward() {
        #expect(FoldSelection.rangeToFold(ranges: ranges, collapsed: [], caretLine: 3) == ranges[2])
        #expect(FoldSelection.rangeToFold(ranges: ranges, collapsed: [ranges[2]], caretLine: 3) == ranges[1])
        #expect(FoldSelection.rangeToFold(ranges: ranges, collapsed: [], caretLine: 12) == nil)
    }

    @Test func unfoldAtCaretNeedsTheHeaderLine() {
        #expect(FoldSelection.rangeToUnfold(collapsed: [ranges[1]], caretLine: 1) == ranges[1])
        #expect(FoldSelection.rangeToUnfold(collapsed: [ranges[1]], caretLine: 2) == nil)
    }

    @Test func foldLevelSkipsRegionsHoldingTheCaret() {
        #expect(FoldSelection.rangesAtLevel(2, ranges: ranges, caretLine: 7) == [ranges[1]])
        #expect(FoldSelection.rangesAtLevel(2, ranges: ranges, caretLine: 0) == [ranges[1], ranges[3]])
    }

    @Test func foldKeyActionsHaveVSCodeIdsAndDefaults() {
        #expect(KeyAction.fold.rawValue == "editor.fold" && KeyAction.unfold.rawValue == "editor.unfold")
        #expect(KeyAction.foldLevel3.foldLevel == 3 && KeyAction.fold.foldLevel == nil)
        let combo = KeyBinding.vscodeDefaults.first { $0.action == .fold }?.combo
        #expect(combo == KeyCombo(key: "[", command: true, option: true))
    }
}

@MainActor
@Suite("Decoration controller")
struct DecorationControllerTests {
    private func fixture(_ text: String) -> (EditorDecorationController, AthenaTextView, AthenaLayoutManager) {
        let storage = NSTextStorage()
        let lm = AthenaLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(container)
        let tv = AthenaTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        tv.string = text
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = tv
        let c = EditorDecorationController()
        c.textView = tv
        c.scrollView = scroll
        c.configure(enabled: true, indentGuides: true, bracketColors: true, stickyScroll: true,
                    language: .swift, tabSize: 4, theme: .athenaDracula)
        c.documentReplaced(foldedLines: [])
        return (c, tv, lm)
    }

    private func waitForRanges(_ c: EditorDecorationController) async {
        let clock = ContinuousClock()
        for _ in 0..<100 where c.ranges.isEmpty { try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(20))) }
    }

    @Test func foldAllAndUnfoldAllHideAndRestoreLines() async {
        let text = "func a() {\n  x\n  y\n}\nfunc b() {\n  z\n  w\n}\n"
        let (c, tv, lm) = fixture(text)
        await waitForRanges(c)
        #expect(c.ranges.count == 2)
        c.perform(.foldAll)
        #expect(lm.foldState.folds.count == 2)
        #expect(tv.string == text)
        guard let container = tv.textContainer else { return }
        lm.ensureLayout(for: container)
        var n = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, _, _ in n += 1 }
        #expect(n == 4)     // two headers and two closers
        c.perform(.unfoldAll)
        #expect(lm.foldState.isEmpty)
    }

    @Test func foldAtCaretMovesCaretToHeaderAndCaretInsideHiddenTextUnfolds() async {
        let text = "func a() {\n  x\n  y\n}\n"
        let (c, tv, lm) = fixture(text)
        await waitForRanges(c)
        tv.setSelectedRange(NSRange(location: 14, length: 0))
        c.perform(.fold)
        #expect(lm.foldState.folds.count == 1)
        #expect(tv.selectedRange().location == 10)
        tv.setSelectedRange(NSRange(location: 15, length: 0))
        c.selectionChanged()
        #expect(lm.foldState.isEmpty)
    }

    @Test func restoresFoldedLinesAndReportsChanges() async {
        let text = "func a() {\n  x\n  y\n}\n"
        let (c, tv, lm) = fixture(text)
        await waitForRanges(c)
        var reported: [[Int]] = []
        c.onFoldedLinesChange = { reported.append($0) }
        c.documentReplaced(foldedLines: [0])
        let clock = ContinuousClock()
        for _ in 0..<100 where lm.foldState.isEmpty { try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(20))) }
        #expect(lm.foldState.folds.count == 1)
        c.perform(.unfoldAll)
        #expect(reported.last == [])
        withExtendedLifetime(tv) {}
    }

    @Test func disabledControllerClearsFolds() async {
        let (c, tv, lm) = fixture("func a() {\n  x\n  y\n}\n")
        await waitForRanges(c)
        c.perform(.foldAll)
        #expect(!lm.foldState.isEmpty)
        c.configure(enabled: false, indentGuides: true, bracketColors: true, stickyScroll: true,
                    language: .swift, tabSize: 4, theme: .athenaDracula)
        #expect(lm.foldState.isEmpty && c.ranges.isEmpty)
        withExtendedLifetime(tv) {}
    }
}
