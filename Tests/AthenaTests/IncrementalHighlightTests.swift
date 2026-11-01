// IncrementalHighlightTests.swift
// Athena — range planning for incremental highlighting and the large-file policy.
// Swift 6, strict concurrency.

import Testing
import Foundation
import AppKit
@testable import Athena

// MARK: - Helpers

private func plan(
    _ text: String,
    insertedAt location: Int,
    length: Int = 1,
    deleted: String = "",
    language: Language = .typescript,
    coloredNewlines: Set<Int> = []
) -> HighlightPlan {
    HighlightPlanner.plan(
        text: text as NSString,
        edit: HighlightEdit(range: NSRange(location: location, length: length), deletedText: deleted),
        language: language,
        isNewlineColored: { coloredNewlines.contains($0) }
    )
}

// MARK: - HighlightPlanner

@Suite struct HighlightPlannerTests {

    @Test func plainEditGetsParagraphWindowWithNeighbours() {
        let text = "aaa\nbbb\nccc\nddd\neee\n"
        // Edit the "c" at index 8 (line 3): window = lines 2...4.
        let result = plan(text, insertedAt: 8)
        #expect(result == .window(NSRange(location: 4, length: 12)))
    }

    @Test func editOnFirstAndLastLineClampsWindow() {
        let text = "one\ntwo\nthree"
        #expect(plan(text, insertedAt: 0) == .window(NSRange(location: 0, length: 8)))
        #expect(plan(text, insertedAt: 12) == .window(NSRange(location: 4, length: 9)))
    }

    @Test func windowSizeIsIndependentOfDocumentSize() {
        let small = (0..<10).map { "let a\($0) = \($0)" }.joined(separator: "\n")
        let large = (0..<10_000).map { "let a\($0) = \($0)" }.joined(separator: "\n")
        let smallLoc = (small as NSString).range(of: "a5").location
        let largeLoc = (large as NSString).range(of: "a5000").location
        guard case .window(let s) = plan(small, insertedAt: smallLoc),
              case .window(let l) = plan(large, insertedAt: largeLoc) else {
            Issue.record("expected window plans"); return
        }
        #expect(s.length < 60)
        #expect(l.length < 60)
    }

    @Test func blockCommentDelimiterForcesFullPass() {
        let text = "let a = 1\n/* note\nlet b = 2\n"
        #expect(plan(text, insertedAt: 10) == .full)   // `/*` inside window
        #expect(plan("x */ y\n", insertedAt: 0, language: .swift) == .full)
    }

    @Test func columnedNewlineInsideMultiLineTokenForcesFullPass() {
        let text = "a\nb\nc\nd\n"
        // Newline at index 3 is coloured (a comment spans it).
        #expect(plan(text, insertedAt: 2, coloredNewlines: [3]) == .full)
        // Newline just before the window is coloured.
        #expect(plan(text, insertedAt: 6, coloredNewlines: [3]) == .full)
        #expect(plan(text, insertedAt: 6) != .full)
    }

    @Test func typingBalancedQuotePairStaysLocal() {
        // Auto-closed pair: inserting `""` leaves an even quote count.
        let text = "const a = \"\"\n"
        #expect(plan(text, insertedAt: 10, length: 2) == .window(NSRange(location: 0, length: 13)))
    }

    @Test func typingUnbalancedQuoteForcesFullPass() {
        let text = "const a = \"\n"
        #expect(plan(text, insertedAt: 10) == .full)
        // Deleting one quote of a pair leaves an odd count.
        #expect(plan("const a = \"x\n", insertedAt: 12, length: 0, deleted: "\"") == .full)
    }

    @Test func editsWithoutQuotesIgnoreBalancedQuotesOnTheLine() {
        let text = "a = \"x\\\"y\"\n"
        #expect(plan(text, insertedAt: 8, length: 1) != .full)
    }

    @Test func backtickAndSingleQuoteAreTreatedLikeDoubleQuote() {
        #expect(plan("x = `a\n", insertedAt: 4) == .full)
        #expect(plan("x = 'a\n", insertedAt: 4) == .full)
    }

    @Test func pythonTripleQuotesForceFullPass() {
        let text = "x = 1\n\"\"\"doc\n"
        #expect(plan(text, insertedAt: 0, language: .python) == .full)
    }

    @Test func markdownEmphasisCharactersForceFullPass() {
        #expect(plan("hello *there\n", insertedAt: 6, language: .markdown) == .full)
        #expect(plan("hello there\n", insertedAt: 6, language: .markdown) != .full)
    }

    @Test func outOfBoundsEditFallsBackToFullPass() {
        #expect(plan("abc", insertedAt: 10) == .full)
    }

    @Test func deletingNewlineMergesParagraphs() {
        // Post-edit text: the newline between "aaa" and "bbb" was removed.
        let text = "aaabbb\nccc\nddd\n"
        #expect(plan(text, insertedAt: 3, length: 0, deleted: "\n") == .window(NSRange(location: 0, length: 11)))
    }
}

// MARK: - In-place application

@Suite @MainActor struct SyntaxHighlighterInPlaceTests {

    private func colors(_ storage: NSTextStorage) -> [NSColor?] {
        (0..<storage.length).map { storage.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor }
    }

    @Test func windowedPassMatchesFullPassForLocalEdit() {
        let highlighter = SyntaxHighlighter(language: .typescript)
        let text = "const a = 1\nfunction f() { return \"x\" }\nlet b = 2 // note\n"
        let storage = NSTextStorage(string: text)
        highlighter.apply(to: storage, range: NSRange(location: 0, length: storage.length))

        // Type " " after `let` on line 3, then re-highlight only the window.
        let loc = (text as NSString).range(of: "let b").location + 3
        storage.replaceCharacters(in: NSRange(location: loc, length: 0), with: " ")
        let result = HighlightPlanner.plan(
            text: storage.mutableString,
            edit: HighlightEdit(range: NSRange(location: loc, length: 1), deletedText: ""),
            language: .typescript,
            isNewlineColored: { _ in false }
        )
        guard case .window(let window) = result else { Issue.record("expected window"); return }
        #expect(window.length < storage.length + 1)
        highlighter.apply(to: storage, range: window)

        let reference = NSTextStorage(attributedString: highlighter.highlight(storage.string))
        #expect(colors(storage) == colors(reference))
    }

    @Test func applyDoesNotReplaceCharacters() {
        let highlighter = SyntaxHighlighter(language: .swift)
        let storage = NSTextStorage(string: "let x = 1\n")
        var editedMasks: [NSTextStorageEditActions] = []
        final class Spy: NSObject, NSTextStorageDelegate {
            var masks: [NSTextStorageEditActions] = []
            func textStorage(_ s: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                             range: NSRange, changeInLength delta: Int) { masks.append(mask) }
        }
        let spy = Spy()
        storage.delegate = spy
        highlighter.apply(to: storage, range: NSRange(location: 0, length: storage.length))
        editedMasks = spy.masks
        #expect(!editedMasks.isEmpty)
        #expect(editedMasks.allSatisfy { !$0.contains(.editedCharacters) })
    }
}

// MARK: - LargeFilePolicy

@Suite struct LargeFilePolicyTests {

    @Test func thresholdIsExclusive() {
        let policy = LargeFilePolicy(thresholdKB: 1)
        #expect(!policy.isLarge(byteCount: 1024))
        #expect(policy.isLarge(byteCount: 1025))
    }

    @Test func zeroOrNegativeDisablesTheMode() {
        #expect(!LargeFilePolicy(thresholdKB: 0).isLarge(byteCount: 500_000_000))
        #expect(!LargeFilePolicy(thresholdKB: -5).isLarge(byteCount: 500_000_000))
    }

    @Test func defaultThresholdIsOneMegabyte() {
        #expect(LargeFilePolicy().thresholdKB == 1024)
    }

    @Test @MainActor func appStateHonoursOverride() {
        let state = AppState()
        state.largeFileThresholdKB = 1
        var tab = TabModel(title: "big.ts")
        tab.content = String(repeating: "a", count: 2048)
        #expect(state.isLargeFile(tab))
        state.enableFeaturesForLargeFile(tab)
        #expect(!state.isLargeFile(tab))
    }
}
