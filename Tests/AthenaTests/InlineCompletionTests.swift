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
                == "  return a + b\n}")
    }

    @Test func continuationStopsAtTheEndOfTheBlock() {
        // The closing brace is already after the caret: don't repeat it,
        // and don't run on into the next function.
        let raw = "return values.reduce((t, v) => t + v, 0)\n}\n\nexport function average() {"
        #expect(GhostTextPolicy.fit(raw, mode: .endOfLine, restOfLine: "", suffix: "\n}\n") == "return values.reduce((t, v) => t + v, 0)")
        // No closer after the caret: the suggestion closes the block itself.
        #expect(GhostTextPolicy.fit(raw, mode: .endOfLine, restOfLine: "", suffix: "") == "return values.reduce((t, v) => t + v, 0)\n}")
        // An inner block the suggestion opens and closes is kept whole.
        let nested = "if (x) {\n  y()\n}\nreturn z"
        #expect(GhostTextPolicy.fit(nested, mode: .endOfLine, restOfLine: "", suffix: "\n}") == nested)
    }

    @Test func bracketBalanceIgnoresStrings() {
        #expect(GhostTextPolicy.bracketBalance(of: "foo(\"(\", [1, 2]") == 1)
        #expect(GhostTextPolicy.bracketBalance(of: "})") == -2)
        #expect(GhostTextPolicy.bracketBalance(of: "'}' + `${a}`") == 0)
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

// MARK: - Driver end to end (real window, real text view, run loop)

@MainActor
@Suite("InlineSuggestionDriver runtime", .serialized)
struct InlineSuggestionDriverRuntimeTests {

    /// A window-hosted text view wired like EditorView wires it: the
    /// driver hears every change and selection change, and has an undo
    /// manager (the window's).
    @MainActor
    final class Harness: NSObject, NSTextViewDelegate {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = AthenaTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let driver = InlineSuggestionDriver()
        var requests: [InlineCompletionQuery] = []
        var answer = "return a + b\n}"

        override init() {
            super.init()
            window.isReleasedWhenClosed = false
            textView.allowsUndo = true
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            window.contentView = textView
            textView.delegate = self
            let label = NSTextField(labelWithString: "")
            textView.addSubview(label)
            driver.ghost.install(label: label)
            driver.textView = textView
            driver.debounceMs = 10
            driver.requestStream = { [weak self] query in
                self?.requests.append(query)
                let answer = self?.answer
                return AsyncStream { continuation in
                    continuation.yield(.finished(answer))
                    continuation.finish()
                }
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            driver.willChangeText(range: range, replacement: replacementString)
            return true
        }
        func textDidChange(_ notification: Notification) { driver.textDidChange() }
        func textViewDidChangeSelection(_ notification: Notification) { driver.selectionDidChange() }

        /// Types like a user: through insertText, so every delegate fires.
        func type(_ s: String) {
            textView.insertText(s, replacementRange: textView.selectedRange())
        }

        func key(_ keyCode: UInt16, _ chars: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
        }
    }

    /// Lets debounce tasks and main-queue hops run.
    private func settle(_ ms: Int = 120) async {
        let clock = ContinuousClock()
        try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(ms)))
    }

    /// Waits (up to 3 s — the first window in a process is slow to come
    /// up) until `condition` holds.
    private func waitFor(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline {
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(20)))
        }
    }

    @Test func suggestShowAcceptUndo() async {
        let h = Harness()
        h.type("function add(a, b) {\n  ")
        await waitFor { h.driver.ghost.hasSuggestion }
        #expect(h.requests.count == 1)
        #expect(h.driver.ghost.suggestion == "return a + b\n}")

        // Tab accepts the whole suggestion as one undoable step.
        #expect(h.driver.handleKey(h.key(48, "\t")))
        #expect(h.textView.string == "function add(a, b) {\n  return a + b\n}")
        #expect(h.driver.ghost.hasSuggestion == false)
        h.textView.undoManager?.undo()
        #expect(h.textView.string == "function add(a, b) {\n  ")
    }

    @Test func typingThroughKeepsTheRest() async {
        let h = Harness()
        h.type("function add(a, b) {\n  ")
        await waitFor { h.driver.ghost.hasSuggestion }
        h.type("ret")
        await settle()
        #expect(h.driver.ghost.suggestion == "urn a + b\n}")
        // No new request while typing what the suggestion says.
        #expect(h.requests.count == 1)
    }

    @Test func movingTheCaretDismisses() async {
        let h = Harness()
        h.type("function add(a, b) {\n  ")
        await waitFor { h.driver.ghost.hasSuggestion }
        #expect(h.driver.ghost.hasSuggestion)
        h.textView.setSelectedRange(NSRange(location: 3, length: 0))
        await settle(30)
        #expect(h.driver.ghost.hasSuggestion == false)
    }

    @Test func escapeDismissesAndIsRemembered() async {
        let h = Harness()
        h.type("function add(a, b) {\n  ")
        await waitFor { h.driver.ghost.hasSuggestion }
        #expect(h.driver.handleKey(h.key(53, "\u{1b}")))
        #expect(h.driver.ghost.hasSuggestion == false)
        // Leave and come back to the very same spot: no suggestion again.
        h.type("x")
        h.textView.doCommand(by: #selector(NSText.deleteBackward(_:)))
        await settle()
        #expect(h.driver.ghost.hasSuggestion == false)
    }

    @Test func wordAcceptAdvances() async {
        let h = Harness()
        h.answer = "return a + b"
        h.type("function add(a, b) {\n  ")
        await waitFor { h.driver.ghost.hasSuggestion }
        #expect(h.driver.handleKey(h.key(124, "", modifiers: .command)))
        #expect(h.textView.string.hasSuffix("  return"))
        #expect(h.driver.ghost.suggestion == " a + b")
    }

    @Test func staleReplyIsDropped() async {
        let h = Harness()
        // The reply arrives after the caret moved: it must not be shown.
        h.driver.requestStream = { [weak tv = h.textView] _ in
            AsyncStream { continuation in
                Task { @MainActor in
                    tv?.setSelectedRange(NSRange(location: 0, length: 0))
                    continuation.yield(.finished("return a + b"))
                    continuation.finish()
                }
            }
        }
        h.type("function add(a, b) {\n  ")
        await settle()
        #expect(h.driver.ghost.hasSuggestion == false)
    }
}
