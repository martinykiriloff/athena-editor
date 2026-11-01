// LSPSymbolRequestTests.swift
// Athena — parsing tests for textDocument/documentHighlight and workspace/symbol.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

@Suite("LSP symbol requests")
struct LSPSymbolRequestTests {
    @Test func parsesDocumentHighlights() {
        let reply = #"{"jsonrpc":"2.0","id":3,"result":[{"range":{"start":{"line":1,"character":4},"end":{"line":1,"character":7}},"kind":2},{"range":{"start":{"line":9,"character":0},"end":{"line":9,"character":3}}},{"bogus":1}]}"#
        let h = LSPManager.parseDocumentHighlights(from: Data(reply.utf8))
        #expect(h.count == 2)
        #expect(h[0] == DocumentHighlight(startLine: 1, startCharacter: 4, endLine: 1, endCharacter: 7, kind: 2))
        #expect(h[1].kind == nil)
    }

    @Test func highlightsNullOrErrorIsEmpty() {
        #expect(LSPManager.parseDocumentHighlights(from: Data(#"{"id":1,"result":null}"#.utf8)).isEmpty)
        #expect(LSPManager.parseDocumentHighlights(from: Data(#"{"id":1,"error":{"code":-32601,"message":"nope"}}"#.utf8)).isEmpty)
    }

    @Test func parsesWorkspaceSymbols() {
        let reply = #"{"id":2,"result":[{"name":"foo","kind":12,"containerName":"Mod","location":{"uri":"file:///a/b.ts","range":{"start":{"line":4,"character":2},"end":{"line":4,"character":5}}}},{"name":"Bar","kind":5,"location":{"uri":"file:///c.ts"}},{"name":"broken"}]}"#
        let s = LSPManager.parseWorkspaceSymbols(from: Data(reply.utf8))
        #expect(s.count == 2)
        #expect(s[0].name == "foo" && s[0].line == 5 && s[0].character == 3 && s[0].containerName == "Mod")
        #expect(s[0].fileURL.path == "/a/b.ts")
        #expect(s[1].line == 1 && s[1].containerName == nil)
    }

    @Test func workspaceSymbolNullIsEmpty() {
        #expect(LSPManager.parseWorkspaceSymbols(from: Data(#"{"id":2,"result":null}"#.utf8)).isEmpty)
    }

    @Test func readsCapabilities() {
        func caps(_ json: String) -> (documentHighlight: Bool, workspaceSymbol: Bool) {
            LSPManager.symbolCapabilities(fromInitializeReply: Data(json.utf8))
        }
        let both = caps(#"{"result":{"capabilities":{"documentHighlightProvider":true,"workspaceSymbolProvider":{"resolveProvider":true}}}}"#)
        #expect(both.documentHighlight && both.workspaceSymbol)
        let none = caps(#"{"result":{"capabilities":{"documentHighlightProvider":false}}}"#)
        #expect(!none.documentHighlight && !none.workspaceSymbol)
        let unknown = caps("garbage")
        #expect(unknown.documentHighlight && unknown.workspaceSymbol)
    }

    @Test func showAllSymbolsBindingIsCmdT() {
        let b = KeyBinding.vscodeDefaults.first { $0.action == .goToWorkspaceSymbol }
        #expect(b?.action.rawValue == "workbench.action.showAllSymbols")
        #expect(b?.combo == KeyCombo(key: "t", command: true))
    }
}
