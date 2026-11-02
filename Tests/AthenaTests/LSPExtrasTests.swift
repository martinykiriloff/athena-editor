// LSPExtrasTests.swift
// Athena — canned-JSON parsing tests and pure-logic tests for the Wave 2 LSP extras.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

@Suite("LSP extras parsing")
struct LSPExtrasParsingTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func readsExtraCapabilities() {
        let reply = #"""
        {"id":1,"result":{"capabilities":{
          "inlayHintProvider":true,
          "semanticTokensProvider":{"legend":{"tokenTypes":["class","function"],"tokenModifiers":["declaration","static"]},"full":{"delta":true}},
          "codeLensProvider":{"resolveProvider":true},
          "callHierarchyProvider":true,
          "typeHierarchyProvider":{},
          "linkedEditingRangeProvider":false,
          "codeActionProvider":{"codeActionKinds":["source.organizeImports"]},
          "workspace":{"fileOperations":{"willRename":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{ts,tsx}","matches":"file"}}]}}}
        }}}
        """#
        let caps = LSPManager.extraCapabilities(fromInitializeReply: data(reply))
        #expect(caps.inlayHints && caps.callHierarchy && caps.typeHierarchy && caps.codeActions)
        #expect(!caps.linkedEditing)
        #expect(caps.codeLens && caps.codeLensResolve)
        #expect(caps.semanticTokensFull)
        #expect(caps.semanticLegend == SemanticTokensLegend(tokenTypes: ["class", "function"], tokenModifiers: ["declaration", "static"]))
        #expect(caps.willRenameFilters == [FileOperationFilter(glob: "**/*.{ts,tsx}", matches: "file")])
        #expect(caps.didRenameFilters.isEmpty)
    }

    @Test func garbageCapabilitiesMeanNothingSupported() {
        #expect(LSPManager.extraCapabilities(fromInitializeReply: data("nope")) == LSPExtraCapabilities())
        #expect(LSPManager.extraCapabilities(fromInitializeReply: data(#"{"id":1,"result":{}}"#)) == LSPExtraCapabilities())
    }

    @Test func globMatching() {
        let ts = [FileOperationFilter(glob: "**/*.{ts,tsx}", matches: "file")]
        #expect(LSPManager.fileOperationMatches(ts, path: "/w/src/a.ts", isDirectory: false))
        #expect(LSPManager.fileOperationMatches(ts, path: "/w/src/deep/b.tsx", isDirectory: false))
        #expect(!LSPManager.fileOperationMatches(ts, path: "/w/src/a.js", isDirectory: false))
        #expect(!LSPManager.fileOperationMatches(ts, path: "/w/src/a.ts", isDirectory: true))
        let folders = [FileOperationFilter(glob: "**", matches: "folder")]
        #expect(LSPManager.fileOperationMatches(folders, path: "/w/src", isDirectory: true))
        #expect(!LSPManager.fileOperationMatches([], path: "/w/a.ts", isDirectory: false))
        let single = [FileOperationFilter(glob: "/w/*.ts")]
        #expect(LSPManager.fileOperationMatches(single, path: "/w/a.ts", isDirectory: false))
        #expect(!LSPManager.fileOperationMatches(single, path: "/w/sub/a.ts", isDirectory: false))
    }

    @Test func parsesInlayHints() {
        let reply = #"{"id":2,"result":[{"position":{"line":1,"character":9},"label":": string","kind":1},{"position":{"line":2,"character":4},"label":[{"value":"count"},{"value":":"}],"kind":2,"paddingRight":true},{"position":{"line":3,"character":0},"label":""},{"bogus":1}]}"#
        let hints = LSPManager.parseInlayHints(from: data(reply))
        #expect(hints.count == 2)
        #expect(hints[0].label == ": string" && hints[0].kind == 1)
        #expect(hints[1].label == "count:" && hints[1].paddingRight)
        #expect(LSPManager.parseInlayHints(from: data(#"{"id":2,"result":null}"#)).isEmpty)
    }

    @Test func decodesSemanticTokens() {
        let legend = SemanticTokensLegend(tokenTypes: ["class", "function", "variable"], tokenModifiers: ["declaration", "static"])
        // (line 0, col 6, len 3, class, declaration) then (+0 line, +5 col, len 4, function, declaration|static),
        // then (+2 lines, col 2, len 1, variable, none), then an out-of-range type, then a partial group.
        let reply = #"{"id":3,"result":{"data":[0,6,3,0,1, 0,5,4,1,3, 2,2,1,2,0, 0,3,2,9,0, 1,1]}}"#
        let spans = LSPManager.decodeSemanticTokens(from: data(reply), legend: legend)
        #expect(spans == [
            SemanticTokenSpan(line: 0, startCharacter: 6, length: 3, tokenType: "class", modifiers: ["declaration"]),
            SemanticTokenSpan(line: 0, startCharacter: 11, length: 4, tokenType: "function", modifiers: ["declaration", "static"]),
            SemanticTokenSpan(line: 2, startCharacter: 2, length: 1, tokenType: "variable", modifiers: []),
        ])
        #expect(LSPManager.decodeSemanticTokens(from: data(#"{"id":3,"result":null}"#), legend: legend).isEmpty)
    }

    @Test func parsesCodeLensesAndResolve() {
        let reply = #"{"id":4,"result":[{"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":5}},"command":{"title":"2 references","command":"editor.action.showReferences","arguments":["file:///a.ts",{"line":3}]}},{"range":{"start":{"line":7,"character":2},"end":{"line":7,"character":9}},"data":{"k":1}},{"nope":1}]}"#
        let lenses = LSPManager.parseCodeLenses(from: data(reply))
        #expect(lenses.count == 2)
        #expect(lenses[0].title == "2 references" && lenses[0].command?.command == "editor.action.showReferences")
        #expect(lenses[0].command?.arguments != nil)
        #expect(lenses[1].command == nil && lenses[1].line == 7)

        let resolved = #"{"id":5,"result":{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"command":{"title":"Run","command":"x.run"}}}"#
        let updated = LSPManager.parseResolvedCodeLens(from: data(resolved), original: lenses[1])
        #expect(updated?.title == "Run" && updated?.line == 7 && updated?.character == 2)
        #expect(LSPManager.parseResolvedCodeLens(from: data(#"{"id":5,"result":null}"#), original: lenses[1]) == nil)
    }

    @Test func parsesHierarchy() {
        let item = #"{"name":"foo","kind":12,"detail":"mod","uri":"file:///a.ts","range":{"start":{"line":1,"character":0},"end":{"line":5,"character":1}},"selectionRange":{"start":{"line":1,"character":9},"end":{"line":1,"character":12}}}"#
        let prepared = LSPManager.parseHierarchyItems(from: data(#"{"id":6,"result":["# + item + "]}"))
        #expect(prepared.count == 1)
        #expect(prepared[0].name == "foo" && prepared[0].line == 1 && prepared[0].character == 9 && prepared[0].detail == "mod")
        #expect(prepared[0].fileURL.path == "/a.ts")

        let incoming = #"{"id":7,"result":[{"from":"# + item + #","fromRanges":[{},{}]},{"from":{"bad":1},"fromRanges":[]}]}"#
        let calls = LSPManager.parseCallHierarchyCalls(from: data(incoming), direction: .incomingCalls)
        #expect(calls.count == 1 && calls[0].callSiteCount == 2)
        let outgoing = #"{"id":8,"result":[{"to":"# + item + #","fromRanges":[{}]}]}"#
        #expect(LSPManager.parseCallHierarchyCalls(from: data(outgoing), direction: .outgoingCalls).first?.callSiteCount == 1)
        #expect(LSPManager.parseHierarchyItems(from: data(#"{"id":6,"result":null}"#)).isEmpty)
    }

    @Test func parsesLinkedEditingRanges() {
        let reply = #"{"id":9,"result":{"ranges":[{"start":{"line":0,"character":1},"end":{"line":0,"character":4}},{"start":{"line":2,"character":2},"end":{"line":2,"character":5}}],"wordPattern":"[a-z]+"}}"#
        let r = LSPManager.parseLinkedEditingRanges(from: data(reply))
        #expect(r?.ranges.count == 2 && r?.wordPattern == "[a-z]+")
        let single = #"{"id":9,"result":{"ranges":[{"start":{"line":0,"character":1},"end":{"line":0,"character":4}}]}}"#
        #expect(LSPManager.parseLinkedEditingRanges(from: data(single)) == nil)
        #expect(LSPManager.parseLinkedEditingRanges(from: data(#"{"id":9,"result":null}"#)) == nil)
    }

    @Test func filtersSourceActionKinds() {
        let reply = #"{"id":10,"result":[{"title":"Organize","kind":"source.organizeImports","edit":{"changes":{"file:///a.ts":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"x"}]}}},{"title":"Fix","kind":"source.fixAll.ts","command":{"title":"Fix","command":"fix"}},{"title":"Other","kind":"refactor","command":{"title":"o","command":"o"}}]}"#
        let all = LSPManager.parseCodeActions(from: data(reply), language: .typescript)
        #expect(LSPManager.filterActions(all, kind: "source.organizeImports").map(\.title) == ["Organize"])
        #expect(LSPManager.filterActions(all, kind: "source.fixAll").map(\.title) == ["Fix"])
    }
}

@Suite("LSP overlay logic")
struct LSPOverlayLogicTests {
    @Test func formatsInlayHintsPerLine() {
        let text = "const total = add(1, 2)\nlet x = 5" as NSString
        let starts = LSPPositions.lineStarts(text)
        let hints = [
            InlayHint(line: 0, character: 11, label: ": number", kind: 1),
            InlayHint(line: 0, character: 18, label: "a:", kind: 2),
            InlayHint(line: 1, character: 5, label: ": number", kind: 1),
            InlayHint(line: 5, character: 0, label: "x", kind: nil),
        ]
        let out = InlayHintFormatter.lineTexts(hints: hints, text: text, lineStarts: starts)
        #expect(out[0] == "total: number  a:")
        #expect(out[1] == "x: number")
        #expect(out[5] == "x")
    }

    @Test func mapsTokenTypesToCategories() {
        #expect(SemanticTokenStyle.category(forType: "class", modifiers: []) == .type)
        #expect(SemanticTokenStyle.category(forType: "method", modifiers: []) == .function)
        #expect(SemanticTokenStyle.category(forType: "variable", modifiers: []) == nil)
        let text = "let Foo = 1\nbar()" as NSString
        let spans = [
            SemanticTokenSpan(line: 0, startCharacter: 4, length: 3, tokenType: "class", modifiers: []),
            SemanticTokenSpan(line: 1, startCharacter: 0, length: 99, tokenType: "function", modifiers: []),
            SemanticTokenSpan(line: 9, startCharacter: 0, length: 1, tokenType: "class", modifiers: []),
        ]
        let r = SemanticTokenStyle.ranges(for: spans, text: text, lineStarts: LSPPositions.lineStarts(text))
        #expect(r.count == 2)
        #expect(r[0].range == NSRange(location: 4, length: 3))
        #expect(r[1].range == NSRange(location: 12, length: 5))   // clamped to the line
    }

    // `<div></div>`: name ranges at 1..<4 and 7..<10.
    @Test func mirrorsInsertionIntoOtherRange() {
        // User typed "v" -> "<divv></div>" (edited = 4..<5 post-edit, delta +1).
        let plan = LinkedEditingMirror.plan(
            ranges: [NSRange(location: 1, length: 3), NSRange(location: 7, length: 3)],
            edited: NSRange(location: 4, length: 1), delta: 1,
            postText: "<divv></div>" as NSString, wordPattern: nil)
        #expect(plan?.edits.count == 1)
        #expect(plan?.edits.first?.range == NSRange(location: 8, length: 3))
        #expect(plan?.edits.first?.text == "divv")
        #expect(plan?.finalRanges == [NSRange(location: 1, length: 4), NSRange(location: 8, length: 4)])
    }

    @Test func mirrorsDeletionFromSecondRangeBackToFirst() {
        // `<div></div>` -> delete the last "v" of the closing tag: `<div></di>`.
        let plan = LinkedEditingMirror.plan(
            ranges: [NSRange(location: 1, length: 3), NSRange(location: 7, length: 3)],
            edited: NSRange(location: 9, length: 0), delta: -1,
            postText: "<div></di>" as NSString, wordPattern: nil)
        #expect(plan?.edits.count == 1)
        #expect(plan?.edits.first?.range == NSRange(location: 1, length: 3))
        #expect(plan?.edits.first?.text == "di")
        #expect(plan?.finalRanges == [NSRange(location: 1, length: 2), NSRange(location: 6, length: 2)])
    }

    @Test func stopsWhenEditLeavesTheRanges() {
        let plan = LinkedEditingMirror.plan(
            ranges: [NSRange(location: 1, length: 3), NSRange(location: 7, length: 3)],
            edited: NSRange(location: 5, length: 1), delta: 1,
            postText: "<div>x</div>" as NSString, wordPattern: nil)
        #expect(plan == nil)
    }

    @Test func wordPatternViolationStopsMirroring() {
        let ranges = [NSRange(location: 1, length: 3), NSRange(location: 7, length: 3)]
        let post = "<di1v></div>" as NSString
        #expect(LinkedEditingMirror.plan(ranges: ranges, edited: NSRange(location: 3, length: 1), delta: 1,
                                         postText: post, wordPattern: "[a-z]+") == nil)
        #expect(LinkedEditingMirror.plan(ranges: ranges, edited: NSRange(location: 3, length: 1), delta: 1,
                                         postText: post, wordPattern: nil) != nil)
    }

    @Test func classifiesCodeLensCommands() {
        #expect(CodeLensAction.classify(command: "editor.action.showReferences") == .showReferences)
        #expect(CodeLensAction.classify(command: "rust-analyzer.showReferences") == .showReferences)
        #expect(CodeLensAction.classify(command: "jest.runTest") == .execute)
    }
}
