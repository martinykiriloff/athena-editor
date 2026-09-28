// EditorNavigationTests.swift
// Athena — problems navigation, reopen closed tab, preview tabs, quick fix
// plumbing and terminal line-editing keys.
// Swift 6, strict concurrency.

import Testing
import Foundation
import AppKit
@testable import Athena

// MARK: - Helpers

private func makeFiles(_ names: [String]) throws -> (URL, [URL]) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("athena-nav-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let urls = try names.map { name -> URL in
        let url = dir.appendingPathComponent(name)
        try "line one\nline two\nline three\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    return (dir, urls)
}

private func diag(_ path: String, _ line: Int, _ column: Int) -> Diagnostic {
    Diagnostic(fileURL: URL(fileURLWithPath: path), line: line, column: column, message: "\(path):\(line)", severity: .error)
}

// MARK: - Problems

@Suite("Next / previous problem")
struct AdjacentProblemTests {
    let sorted = [diag("/a.ts", 3, 1), diag("/a.ts", 10, 5), diag("/b.ts", 1, 1)]

    @Test func forwardFindsFirstAfterCaretAndWraps() {
        let a = URL(fileURLWithPath: "/a.ts")
        #expect(AppState.adjacentDiagnostic(in: sorted, fileURL: a, line: 1, column: 1, forward: true) == sorted[0])
        // Sitting on a problem moves past it.
        #expect(AppState.adjacentDiagnostic(in: sorted, fileURL: a, line: 3, column: 1, forward: true) == sorted[1])
        // Across files, then wrapping to the top.
        #expect(AppState.adjacentDiagnostic(in: sorted, fileURL: a, line: 20, column: 1, forward: true) == sorted[2])
        let b = URL(fileURLWithPath: "/b.ts")
        #expect(AppState.adjacentDiagnostic(in: sorted, fileURL: b, line: 5, column: 1, forward: true) == sorted[0])
    }

    @Test func backwardFindsLastBeforeCaretAndWraps() {
        let a = URL(fileURLWithPath: "/a.ts")
        #expect(AppState.adjacentDiagnostic(in: sorted, fileURL: a, line: 10, column: 5, forward: false) == sorted[0])
        #expect(AppState.adjacentDiagnostic(in: sorted, fileURL: a, line: 1, column: 1, forward: false) == sorted[2])
    }

    @Test func noFileStartsAtEnds() {
        #expect(AppState.adjacentDiagnostic(in: sorted, fileURL: nil, line: 1, column: 1, forward: true) == sorted[0])
        #expect(AppState.adjacentDiagnostic(in: sorted, fileURL: nil, line: 1, column: 1, forward: false) == sorted[2])
        #expect(AppState.adjacentDiagnostic(in: [], fileURL: nil, line: 1, column: 1, forward: true) == nil)
    }
}

@Suite("Problems navigation")
@MainActor
struct ProblemsNavigationTests {
    @Test func clickingAProblemOpensFileAtPosition() async throws {
        let (dir, urls) = try makeFiles(["x.ts"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()

        await state.navigateToDiagnostic(Diagnostic(fileURL: urls[0], line: 2, column: 4, message: "m", severity: .warning))

        #expect(state.activeTab?.fileURL == urls[0])
        #expect(state.pendingNavigationTarget?.location == DefinitionLocation(fileURL: urls[0], line: 2, character: 4))
    }

    @Test func f8WalksDiagnosticsAcrossFiles() async throws {
        let (dir, urls) = try makeFiles(["a.ts", "b.ts"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.diagnostics = [
            urls[0]: [Diagnostic(fileURL: urls[0], line: 2, column: 1, message: "first", severity: .error)],
            urls[1]: [Diagnostic(fileURL: urls[1], line: 1, column: 3, message: "second", severity: .error)],
        ]

        await state.perform(.nextProblem)
        #expect(state.activeTab?.fileURL == urls[0])

        // The editor reports the caret move once it jumps.
        let tab = try #require(state.activeTab)
        state.setCursorPosition(tabId: tab.id, in: .primary, line: 2, column: 1)
        await state.perform(.nextProblem)
        #expect(state.activeTab?.fileURL == urls[1])
        #expect(state.pendingNavigationTarget?.location.character == 3)
    }
}

// MARK: - Tabs

@Suite("Reopen closed editor")
@MainActor
struct ReopenClosedTabTests {
    @Test func reopensMostRecentAtCursor() async throws {
        let (dir, urls) = try makeFiles(["a.ts", "b.ts"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        await state.openFile(urls[0])
        await state.openFile(urls[1])
        let b = try #require(state.activeTab)
        state.setCursorPosition(tabId: b.id, in: .primary, line: 3, column: 2)

        state.closeTab(b.id)
        #expect(state.openTabs.count == 1)

        await state.perform(.reopenClosedTab)
        #expect(state.activeTab?.fileURL == urls[1])
        #expect(state.pendingNavigationTarget?.location == DefinitionLocation(fileURL: urls[1], line: 3, character: 2))
        #expect(state.recentlyClosedTabs.isEmpty)
    }

    @Test func skipsDeletedAndAlreadyOpenFiles() async throws {
        let (dir, urls) = try makeFiles(["a.ts", "b.ts", "c.ts"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        for url in urls { await state.openFile(url) }
        for tab in state.openTabs { state.closeTab(tab.id) }   // a, b, c closed in order
        try FileManager.default.removeItem(at: urls[2])        // c deleted
        await state.openFile(urls[1])                          // b open again

        await state.reopenClosedTab()
        #expect(state.activeTab?.fileURL == urls[0])
    }

    @Test func emptyStackSaysSo() async {
        let state = AppState()
        await state.reopenClosedTab()
        #expect(state.statusMessage == "No closed editors to reopen")
    }
}

@Suite("Preview tabs")
@MainActor
struct PreviewTabTests {
    @Test func singleClickReplacesPreviewInPlace() async throws {
        let (dir, urls) = try makeFiles(["a.ts", "b.ts", "c.ts"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        await state.openFile(urls[0])                 // permanent
        await state.openFile(urls[1], preview: true)
        #expect(state.openTabs.map(\.isPreview) == [false, true])

        await state.openFile(urls[2], preview: true)
        #expect(state.openTabs.map(\.fileURL) == [urls[0], urls[2]])
        #expect(state.activeTab?.fileURL == urls[2])
    }

    @Test func editingSavingOrKeepOpenPins() async throws {
        let (dir, urls) = try makeFiles(["a.ts", "b.ts", "c.ts"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()

        await state.openFile(urls[0], preview: true)
        state.updateTabContent(try #require(state.activeTab).id, content: "edited")
        #expect(state.activeTab?.isPreview == false)

        await state.openFile(urls[1], preview: true)
        await state.saveActiveTab()
        #expect(state.activeTab?.isPreview == false)

        await state.openFile(urls[2], preview: true)
        state.keepOpen(urls[2])
        #expect(state.activeTab?.isPreview == false)
        #expect(state.openTabs.count == 3)
    }

    @Test func doubleClickBeforeOpenFinishesOpensPermanent() async throws {
        let (dir, urls) = try makeFiles(["a.ts"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.keepOpen(urls[0])   // lands before the preview open reads the file
        await state.openFile(urls[0], preview: true)
        #expect(state.activeTab?.isPreview == false)
    }

    @Test func deliberateOpenPinsExistingPreview() async throws {
        let (dir, urls) = try makeFiles(["a.ts"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        await state.openFile(urls[0], preview: true)
        await state.openFile(urls[0])
        #expect(state.openTabs.count == 1)
        #expect(state.activeTab?.isPreview == false)
    }
}

// MARK: - Quick fix plumbing

@Suite("Code actions")
struct CodeActionParsingTests {
    @Test func parsesActionsAndCommandsQuickFixesFirst() throws {
        let reply = #"""
        {"jsonrpc":"2.0","id":4,"result":[
          {"title":"Extract function","kind":"refactor.extract","edit":{"changes":{"file:///x.ts":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"y"}]}}},
          {"title":"Organize imports","command":"_typescript.organizeImports","arguments":["/x.ts"]},
          {"title":"Add missing import","kind":"quickfix","edit":{"documentChanges":[{"textDocument":{"uri":"file:///x.ts","version":2},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"import a;\n"}]}]}},
          {"title":"Preferred fix","kind":"quickfix","isPreferred":true,"command":{"title":"t","command":"fix.it"}},
          {"title":"Disabled","kind":"quickfix","disabled":{"reason":"no"},"edit":{"changes":{}}}
        ]}
        """#
        let actions = LSPManager.parseCodeActions(from: Data(reply.utf8), language: .typescript)

        #expect(actions.map(\.title) == ["Preferred fix", "Add missing import", "Extract function", "Organize imports"])
        #expect(actions[0].command?.command == "fix.it")
        #expect(actions[1].edits[URL(string: "file:///x.ts")!]?.first?.newText == "import a;\n")
        let args = try #require(actions[3].command?.arguments)
        #expect(try JSONSerialization.jsonObject(with: args) as? [String] == ["/x.ts"])
    }

    @Test func contextKeepsOnlyDiagnosticsOnRequestedLines() {
        func d(_ start: Int, _ end: Int) -> [String: Any] {
            ["range": ["start": ["line": start, "character": 0], "end": ["line": end, "character": 1]], "message": "\(start)"]
        }
        let kept = LSPManager.diagnostics([d(0, 0), d(2, 4), d(6, 6)], touchingLines: 3...5)
        #expect(kept.map { $0["message"] as? String } == ["2"])
    }

    @Test func sameOffsetInsertsKeepArrayOrder() {
        let edits = [
            LSPTextEdit(startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0, newText: "A"),
            LSPTextEdit(startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0, newText: "B"),
        ]
        #expect(applyLSPTextEdits(edits, to: "x") == "ABx")
    }

    @Test func changedRangeIsMinimal() throws {
        // "let" and "const" share their final "t".
        let (range, text) = try #require(EditorView.Coordinator.changedRange(from: "let a = 1", to: "const a = 1"))
        #expect(range == NSRange(location: 0, length: 2))
        #expect(text == "cons")
        #expect(EditorView.Coordinator.changedRange(from: "same", to: "same") == nil)
        // An emoji swap must not split a surrogate pair.
        let (r2, t2) = try #require(EditorView.Coordinator.changedRange(from: "a😀b", to: "a😃b"))
        #expect(r2 == NSRange(location: 1, length: 2))
        #expect(t2 == "😃")
    }
}

@Suite("Workspace edits")
@MainActor
struct WorkspaceEditTests {
    @Test func openFilesChangeInBufferOthersOnDisk() async throws {
        let (dir, urls) = try makeFiles(["open.ts", "closed.ts"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        await state.openFile(urls[0])
        let insert = [LSPTextEdit(startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0, newText: "// x\n")]

        let applied = await state.applyWorkspaceEdit([urls[0]: insert, urls[1]: insert])

        #expect(applied)
        #expect(state.activeTab?.content.hasPrefix("// x\nline one") == true)
        #expect(state.activeTab?.isDirty == true)
        #expect(try String(contentsOf: urls[0], encoding: .utf8).hasPrefix("line one"))
        #expect(try String(contentsOf: urls[1], encoding: .utf8).hasPrefix("// x\nline one"))
    }
}

// MARK: - Terminal

@Suite("Terminal line-editing keys")
struct TerminalKeyTests {
    @Test func mapsMacShortcutsToReadlineBytes() {
        #expect(TerminalView.lineEditingBytes(keyCode: 51, modifiers: .command) == [0x15])
        #expect(TerminalView.lineEditingBytes(keyCode: 123, modifiers: .command) == [0x01])
        #expect(TerminalView.lineEditingBytes(keyCode: 124, modifiers: .command) == [0x05])
        #expect(TerminalView.lineEditingBytes(keyCode: 123, modifiers: .option) == [0x1B, 0x62])
        #expect(TerminalView.lineEditingBytes(keyCode: 124, modifiers: .option) == [0x1B, 0x66])
        #expect(TerminalView.lineEditingBytes(keyCode: 51, modifiers: .option) == [0x1B, 0x7F])
    }

    @Test func leavesOtherCombosAlone() {
        #expect(TerminalView.lineEditingBytes(keyCode: 123, modifiers: []) == nil)
        #expect(TerminalView.lineEditingBytes(keyCode: 123, modifiers: [.command, .shift]) == nil)
        #expect(TerminalView.lineEditingBytes(keyCode: 0, modifiers: .command) == nil)
        // Caps Lock / fn don't block the match.
        #expect(TerminalView.lineEditingBytes(keyCode: 123, modifiers: [.command, .capsLock, .function]) == [0x01])
    }
}
