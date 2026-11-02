// InlineCompletionTests.swift
// Athena — ghost-text policy, shaping, partial accept, and insertion.
// Swift 6, strict concurrency.

import Testing
import Foundation
import AppKit
@testable import Athena

// MARK: - Mode (end of line vs mid-line)

@Suite("GhostTextPolicy mode")
struct GhostTextModeTests {
    private func mode(_ source: String, manual: Bool = false) -> InlineCompletionMode? {
        let text = source as NSString
        let caret = text.range(of: "|").location
        let stripped = text.replacingOccurrences(of: "|", with: "") as NSString
        return GhostTextPolicy.mode(text: stripped, cursor: caret, isPopupVisible: false, manual: manual)
    }

    @Test func closersToTheRightAreMidLine() {
        #expect(mode("foo(|)") == .midLine)
        #expect(mode("const user = await fetchUser(|);") == .midLine)
        #expect(mode("const s = \"|\"") == .midLine)
    }

    @Test func realCodeToTheRightStaysQuiet() {
        #expect(mode("const x = | + total") == nil)
        #expect(mode("call(| other)") == nil)
    }

    @Test func endOfLineIsStillEndOfLine() {
        #expect(mode("const total = |") == .endOfLine)
        #expect(mode("function run() {\n  |   \n}") == .endOfLine)
    }

    @Test func manualTriggerAllowsMidIdentifier() {
        #expect(mode("const total = cal|") == nil)
        #expect(mode("const total = cal|", manual: true) == .endOfLine)
        // Still needs something to complete from.
        #expect(mode("   |", manual: true) == nil)
    }

    @Test func manualShowsShortAnswers() {
        #expect(GhostTextPolicy.isSubstantial("total") == false)
        #expect(GhostTextPolicy.isSubstantial("total", manual: true) == true)
    }
}

// MARK: - Fitting a suggestion to its slot

@Suite("GhostTextPolicy fit")
struct GhostTextFitTests {
    @Test func midLineDropsRepeatedClosers() {
        #expect(GhostTextPolicy.fit("userId)", mode: .midLine, restOfLine: ")", suffix: ")") == "userId")
        #expect(GhostTextPolicy.fit("id, name);", mode: .midLine, restOfLine: ");", suffix: ");") == "id, name")
    }

    @Test func midLineKeepsOneLine() {
        #expect(GhostTextPolicy.fit("a, b)\nmore()", mode: .midLine, restOfLine: ")", suffix: ")") == "a, b")
    }

    @Test func midLineWithNothingLeftIsNil() {
        #expect(GhostTextPolicy.fit(")", mode: .midLine, restOfLine: ")", suffix: ")") == nil)
    }

    @Test func endOfLineStopsWhereTheFollowingCodeRepeats() {
        let suggestion = "  return a + b\n}\n\nfunction next() {"
        let suffix = "\n\nfunction next() {\n  return 1\n}"
        #expect(GhostTextPolicy.fit(suggestion, mode: .endOfLine, restOfLine: "", suffix: suffix)
                == "  return a + b\n}\n")
    }

    @Test func endOfLineLeavesUnrelatedTextAlone() {
        let s = "items.map(item => item.id)"
        #expect(GhostTextPolicy.fit(s, mode: .endOfLine, restOfLine: "", suffix: "\n}") == s)
    }
}

// MARK: - Partial accept

@Suite("GhostTextPolicy partial accept")
struct GhostTextChunkTests {
    @Test func nextWordTakesLeadingSpaceAndOneWord() {
        #expect(GhostTextPolicy.nextWordChunk(of: "items.map(x)") == "items")
        #expect(GhostTextPolicy.nextWordChunk(of: ".map(x)") == ".")
        #expect(GhostTextPolicy.nextWordChunk(of: "  return a") == "  return")
        #expect(GhostTextPolicy.nextWordChunk(of: "(x) => y") == "(")
        #expect(GhostTextPolicy.nextWordChunk(of: "$el.value") == "$el")
    }

    @Test func nextWordNeverCrossesALine() {
        #expect(GhostTextPolicy.nextWordChunk(of: "\n  next") == "\n")
        #expect(GhostTextPolicy.nextWordChunk(of: "end\nnext") == "end")
    }

    @Test func nextLineIncludesTheNewline() {
        #expect(GhostTextPolicy.nextLineChunk(of: "a()\nb()") == "a()\n")
        #expect(GhostTextPolicy.nextLineChunk(of: "only") == "only")
    }
}

// MARK: - Insertion and type-through

@MainActor
@Suite("GhostTextController insertion")
struct GhostTextInsertionTests {
    private func makeTextView(_ text: String) -> AthenaTextView {
        let tv = AthenaTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = text
        return tv
    }

    @Test func insertBypassesTheAutoCloseHook() {
        let tv = makeTextView("let x = ")
        var hookCalls = 0
        // An auto-close hook that would turn "(" into "()" if consulted.
        tv.onInsertText = { _ in hookCalls += 1; return true }
        #expect(GhostTextController.insert("foo(", at: 8, in: tv))
        #expect(tv.string == "let x = foo(")
        #expect(hookCalls == 0)
    }

    @Test func caretLandsAfterInsertedTextInUTF16() {
        // The emoji is 2 UTF-16 units; a Character count would be off by one.
        let tv = makeTextView("😀 = ")
        let location = ("😀 = " as NSString).length
        #expect(GhostTextController.insert("👍 done", at: location, in: tv))
        #expect(tv.selectedRange() == NSRange(location: (tv.string as NSString).length, length: 0))
    }

    @Test func advanceKeepsTheRestOfTheSuggestion() {
        let tv = makeTextView("x = ")
        let label = NSTextField(labelWithString: "")
        tv.addSubview(label)
        let ghost = GhostTextController()
        ghost.install(label: label)
        ghost.show(text: "items.length", at: 4, font: .monospacedSystemFont(ofSize: 12, weight: .regular), in: tv)
        #expect(ghost.hasSuggestion)
        // Type the first three characters, as the user would.
        tv.string = "x = ite"
        #expect(ghost.advance(typed: "ite"))
        #expect(ghost.suggestion == "ms.length")
        #expect(ghost.anchor == 7)
        // A keystroke that disagrees with the suggestion dismisses it.
        #expect(ghost.advance(typed: "q") == false)
        #expect(ghost.hasSuggestion == false)
    }

    @Test func typingTheWholeSuggestionDismissesIt() {
        let tv = makeTextView("x = ")
        let label = NSTextField(labelWithString: "")
        tv.addSubview(label)
        let ghost = GhostTextController()
        ghost.install(label: label)
        ghost.show(text: "abc", at: 4, font: .monospacedSystemFont(ofSize: 12, weight: .regular), in: tv)
        #expect(ghost.advance(typed: "abc") == false)
        #expect(ghost.hasSuggestion == false)
    }
}

// MARK: - Driver position keys

@Suite("InlineSuggestionDriver helpers")
struct InlineSuggestionDriverHelperTests {
    @Test func positionKeyIgnoresDistantEdits() {
        // Everything within the key's 300-character window is shared.
        let near = String(repeating: "x", count: 400) + "function f() {\n  "
        let a = InlineSuggestionDriver.positionKey(prefix: String(repeating: "a", count: 500) + near, suffix: "\n}")
        let b = InlineSuggestionDriver.positionKey(prefix: String(repeating: "b", count: 500) + near, suffix: "\n}")
        #expect(a == b)
    }

    @Test func restOfLineStopsAtTheNewline() {
        let ns = "call(x);\nnext" as NSString
        #expect(InlineSuggestionDriver.restOfLine(in: ns, from: 5) == "x);")
        #expect(InlineSuggestionDriver.restOfLine(in: ns, from: 8) == "")
    }
}
