// FoldingTests.swift
// Athena — fold range computation, bracket pairing, fold state edit tracking, and layout-level hiding.
// Swift 6, strict concurrency.

import Testing
import AppKit
import Foundation
@testable import Athena

@Suite("Fold range computation")
struct FoldRangeComputationTests {

    @Test func bracesFoldAndKeepClosingLineVisible() {
        let text = "func a() {\n  let x = 1\n  let y = 2\n}\nlet z = 3\n"
        #expect(FoldingRangeComputer.compute(text: text, language: .swift) == [FoldRange(startLine: 0, endLine: 2)])
    }

    @Test func nestedBlocksAndElseChain() {
        let text = "if a {\n  b()\n} else {\n  c()\n  d()\n}\n"
        let r = FoldingRangeComputer.compute(text: text, language: .typescript)
        #expect(r == [FoldRange(startLine: 0, endLine: 1), FoldRange(startLine: 2, endLine: 4)])
    }

    @Test func bracesInStringsAndCommentsAreIgnored() {
        let text = "let s = \"{\"\n// }\nlet t = '}'\nfoo()\n"
        #expect(FoldingRangeComputer.compute(text: text, language: .typescript).isEmpty)
        let ok = "let s = \"}\" // {\nfunc f() {\n  x\n}\n"
        #expect(FoldingRangeComputer.compute(text: ok, language: .swift) == [FoldRange(startLine: 1, endLine: 2)])
    }

    @Test func blockCommentFolds() {
        let text = "/**\n * doc\n */\nlet x = 1\n"
        #expect(FoldingRangeComputer.compute(text: text, language: .javascript) == [FoldRange(startLine: 0, endLine: 2)])
    }

    @Test func emptyBlockDoesNotFold() {
        #expect(FoldingRangeComputer.compute(text: "{\n}\n", language: .swift).isEmpty)
    }

    @Test func rustLifetimeAndCharLiteral() {
        let text = "fn f<'a>(c: char) {\n  let q = '{';\n  x\n}\n"
        #expect(FoldingRangeComputer.compute(text: text, language: .rust) == [FoldRange(startLine: 0, endLine: 2)])
    }

    @Test func tripleQuotedSwiftStringIsOpaque() {
        let text = "let s = \"\"\"\n{\n\"\"\"\nfunc f() {\n  x\n}\n"
        #expect(FoldingRangeComputer.compute(text: text, language: .swift) == [FoldRange(startLine: 3, endLine: 4)])
    }

    @Test func indentationFoldsPython() {
        let text = "def f():\n    a = 1\n\n    if a:\n        b\n    c\nx = 1\n"
        let r = FoldingRangeComputer.compute(text: text, language: .python)
        #expect(r == [FoldRange(startLine: 0, endLine: 5), FoldRange(startLine: 3, endLine: 4)])
    }

    @Test func lspRangesDropTheClosingBraceLine() {
        let text = "func a() {\n  x\n}\n"
        let r = FoldingRangeComputer.normalize(lsp: [FoldRange(startLine: 0, endLine: 2)], text: text)
        #expect(r == [FoldRange(startLine: 0, endLine: 1)])
        let imports = "import a\nimport b\nlet x = 1\n"
        #expect(FoldingRangeComputer.normalize(lsp: [FoldRange(startLine: 0, endLine: 1)], text: imports)
                == [FoldRange(startLine: 0, endLine: 1)])
    }

    @Test func nestingDepths() {
        let ranges = [FoldRange(startLine: 0, endLine: 9), FoldRange(startLine: 1, endLine: 3),
                      FoldRange(startLine: 2, endLine: 3), FoldRange(startLine: 5, endLine: 8)]
        #expect(FoldingRangeComputer.depths(of: ranges) == [1, 2, 3, 2])
    }

    @Test func parsesLSPReply() {
        let json = #"{"jsonrpc":"2.0","id":1,"result":[{"startLine":1,"endLine":4,"kind":"region"},{"startLine":6,"endLine":7}]}"#
        let ranges = LSPManager.parseFoldingRanges(from: Data(json.utf8))
        #expect(ranges == [FoldRange(startLine: 1, endLine: 4), FoldRange(startLine: 6, endLine: 7)])
        #expect(LSPManager.parseFoldingRanges(from: Data(#"{"id":1,"result":null}"#.utf8)) == nil)
    }
}

@Suite("Bracket pairing")
struct BracketPairingTests {
    @Test func pairsAndDepths() {
        let p = BracketScanner.pairing(for: "a(b[c]{d})", language: .typescript)
        #expect(p.unmatched.isEmpty)
        #expect(p.pairs.map(\.depth) == [0, 1, 1])
    }

    @Test func mismatchedCloserIsUnmatched() {
        let p = BracketScanner.pairing(for: "(]", language: .swift)
        #expect(p.pairs.isEmpty)
        #expect(p.unmatched == [0, 1])
    }

    @Test func ignoresBracketsInStrings() {
        let p = BracketScanner.pairing(for: "f(\")\")", language: .swift)
        #expect(p.pairs.count == 1 && p.unmatched.isEmpty)
    }

    @Test func jumpTargets() {
        let pairs = BracketScanner.pairing(for: "f(a, (b))", language: .swift).pairs
        #expect(BracketScanner.jumpTarget(pairs: pairs, caret: 1) == 9)
        #expect(BracketScanner.jumpTarget(pairs: pairs, caret: 9) == 1)
        #expect(BracketScanner.jumpTarget(pairs: pairs, caret: 3) == 8)
        #expect(BracketScanner.jumpTarget(pairs: [], caret: 0) == nil)
    }
}

@Suite("Fold state")
struct FoldStateTests {
    @Test func hiddenRangeCoversHeaderNewlineThroughLastHiddenLine() {
        let text = "a {\nb\nc\n}\n"
        let starts = FoldingRangeComputer.lineStarts(Array(text.utf16))
        let r = FoldState.hiddenRange(for: FoldRange(startLine: 0, endLine: 2), lineStarts: starts, textLength: text.utf16.count)
        #expect(r == NSRange(location: 3, length: 4))
    }

    @Test func editsBeforeShiftEditsInsideDrop() {
        var s = FoldState()
        s.fold(NSRange(location: 10, length: 5))
        #expect(s.applyEdit(edited: NSRange(location: 2, length: 3), delta: 3, newLength: 30).isEmpty)
        #expect(s.folds == [NSRange(location: 13, length: 5)])
        #expect(s.applyEdit(edited: NSRange(location: 40, length: 1), delta: 1, newLength: 60).isEmpty)
        #expect(s.folds == [NSRange(location: 13, length: 5)])
        let dropped = s.applyEdit(edited: NSRange(location: 15, length: 1), delta: 1, newLength: 31)
        #expect(dropped.count == 1 && s.isEmpty)
    }

    @Test func hiddenQueriesAndNesting() {
        var s = FoldState()
        s.fold(NSRange(location: 5, length: 10))
        s.fold(NSRange(location: 8, length: 3))
        #expect(s.merged == [NSRange(location: 5, length: 10)])
        #expect(s.isHidden(5) && s.isHidden(14) && !s.isHidden(15) && !s.isHidden(4))
        #expect(s.folds(hiddenBy: NSRange(location: 5, length: 0)).isEmpty)
        #expect(s.folds(hiddenBy: NSRange(location: 9, length: 0)).count == 2)
        #expect(s.folds(hiddenBy: NSRange(location: 0, length: 40)).isEmpty)
    }
}

@MainActor
@Suite("Fold layout")
struct FoldLayoutTests {

    private func makeLayout(_ text: String) -> (AthenaLayoutManager, NSTextStorage, NSTextContainer) {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        let lm = AthenaLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(container)
        return (lm, storage, container)
    }

    private func fragmentCount(_ lm: AthenaLayoutManager, _ container: NSTextContainer) -> Int {
        lm.ensureLayout(for: container)
        var n = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, _, _ in n += 1 }
        return n
    }

    @Test func foldingMergesLinesWithoutChangingText() {
        let text = "a {\nb\nc\n}\nz"
        let (lm, storage, container) = makeLayout(text)
        #expect(fragmentCount(lm, container) == 5)
        var state = FoldState()
        state.fold(NSRange(location: 3, length: 4))
        lm.setFoldState(state)
        #expect(fragmentCount(lm, container) == 3)
        #expect(storage.string == text)
        lm.setFoldState(FoldState())
        #expect(fragmentCount(lm, container) == 5)
    }

    @Test func editInsideFoldOpensItAndEditBeforeShiftsIt() {
        let (lm, storage, container) = makeLayout("a {\nb\nc\n}\nz")
        var state = FoldState()
        state.fold(NSRange(location: 3, length: 4))
        lm.setFoldState(state)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "xx")
        #expect(lm.foldState.folds == [NSRange(location: 5, length: 4)])
        #expect(fragmentCount(lm, container) == 3)
        storage.replaceCharacters(in: NSRange(location: 6, length: 1), with: "B")
        #expect(lm.foldState.isEmpty)
        #expect(fragmentCount(lm, container) == 5)
    }
}
