// ClaudeSessionHistoryTests.swift
// Athena — rebuilding a reopened conversation from the CLI's transcript.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

@Suite("Claude session history loading")
struct ClaudeSessionHistoryTests {

    // MARK: - Fixture lines (the CLI's transcript shape)

    private func user(_ uuid: String, parent: String?, text: String, meta: Bool = false) -> String {
        let p = parent.map { "\"\($0)\"" } ?? "null"
        let content = try! String(data: JSONEncoder().encode(text), encoding: .utf8)!
        return #"{"parentUuid":\#(p),"isSidechain":false,"type":"user","isMeta":\#(meta),"message":{"role":"user","content":[{"type":"text","text":\#(content)}]},"uuid":"\#(uuid)","timestamp":"2026-11-02T20:00:00.000Z"}"#
    }

    private func assistantText(_ uuid: String, parent: String, text: String) -> String {
        #"{"parentUuid":"\#(parent)","isSidechain":false,"type":"assistant","message":{"id":"msg_\#(uuid)","role":"assistant","content":[{"type":"text","text":"\#(text)"}]},"uuid":"\#(uuid)","timestamp":"2026-11-02T20:00:01.000Z"}"#
    }

    private func thinking(_ uuid: String, parent: String, text: String) -> String {
        #"{"parentUuid":"\#(parent)","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"\#(text)","signature":"x"}]},"uuid":"\#(uuid)","timestamp":"2026-11-02T20:00:01.000Z"}"#
    }

    private func toolUse(_ uuid: String, parent: String, id: String, name: String = "Read", path: String = "/p/a.ts") -> String {
        #"{"parentUuid":"\#(parent)","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{"file_path":"\#(path)"}}]},"uuid":"\#(uuid)","timestamp":"2026-11-02T20:00:02.000Z"}"#
    }

    private func toolResult(_ uuid: String, parent: String, id: String, text: String, error: Bool = false) -> String {
        #"{"parentUuid":"\#(parent)","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"\#(text)","is_error":\#(error)}]},"uuid":"\#(uuid)","timestamp":"2026-11-02T20:00:04.000Z"}"#
    }

    private func history(_ lines: [String], root: URL? = URL(fileURLWithPath: "/p"), limit: Int = 600) -> ClaudeSessionStore.History {
        ClaudeSessionStore.history(fromTranscript: Data(lines.joined(separator: "\n").utf8), workspaceRoot: root, limit: limit)
    }

    private func texts(_ items: [ClaudeTimelineItem]) -> [String] {
        items.map { item in
            switch item.kind {
            case .user(let text, _, _):      return "user: \(text)"
            case .assistant(let text, _):    return "claude: \(text)"
            case .thinking(let text, _):     return "thinking: \(text)"
            case .tool(let call):            return "tool \(call.name) \(call.status.rawValue): \(call.resultText)"
            case .notice(let text, _):       return "notice: \(text)"
            case .permission:                return "permission"
            case .summary:                   return "summary"
            }
        }
    }

    // MARK: - Tests

    @Test func rebuildsAConversationWithToolResults() {
        let h = history([
            #"{"type":"ai-title","aiTitle":"Fix bug"}"#,
            user("u1", parent: nil, text: "Fix the checkout bug"),
            thinking("a1", parent: "u1", text: "Look at the cart"),
            toolUse("a2", parent: "a1", id: "t1"),
            toolResult("u2", parent: "a2", id: "t1", text: "file contents"),
            assistantText("a3", parent: "u2", text: "Fixed it."),
        ])
        #expect(texts(h.items) == [
            "user: Fix the checkout bug",
            "thinking: Look at the cart",
            "tool Read success: file contents",
            "claude: Fixed it.",
        ])
        #expect(h.omitted == 0)
        // Timestamps give the call a duration, like a live one.
        #expect(h.items[2].toolCall?.duration == 2)
    }

    /// Parallel calls fork the chain: each result hangs off its own call
    /// while the next call continues. Every result must still be joined.
    @Test func keepsResultsOfParallelCalls() {
        let h = history([
            user("u1", parent: nil, text: "Read both files"),
            toolUse("a1", parent: "u1", id: "t1", path: "/p/a.ts"),
            toolUse("a2", parent: "a1", id: "t2", path: "/p/b.ts"),
            toolResult("u2", parent: "a1", id: "t1", text: "A"),
            toolResult("u3", parent: "a2", id: "t2", text: "B"),
            assistantText("a3", parent: "u3", text: "Done."),
        ])
        #expect(texts(h.items) == [
            "user: Read both files",
            "tool Read success: A",
            "tool Read success: B",
            "claude: Done.",
        ])
    }

    /// A rewind leaves the abandoned turns in the file; only the branch the
    /// conversation continued from is shown.
    @Test func dropsTurnsARewindAbandoned() {
        let h = history([
            user("u1", parent: nil, text: "First question"),
            assistantText("a1", parent: "u1", text: "First answer"),
            user("u2", parent: "a1", text: "Abandoned follow-up"),
            assistantText("a2", parent: "u2", text: "Abandoned answer"),
            user("u3", parent: "a1", text: "Edited follow-up"),
            assistantText("a3", parent: "u3", text: "Kept answer"),
        ])
        #expect(texts(h.items) == [
            "user: First question",
            "claude: First answer",
            "user: Edited follow-up",
            "claude: Kept answer",
        ])
    }

    /// The chain also runs through attachment lines, which carry uuids too.
    @Test func followsTheChainThroughAttachmentLines() {
        let h = history([
            #"{"parentUuid":null,"type":"attachment","attachment":{"type":"file"},"uuid":"x1"}"#,
            user("u1", parent: "x1", text: "Hello"),
            assistantText("a1", parent: "u1", text: "Hi"),
        ])
        #expect(texts(h.items) == ["user: Hello", "claude: Hi"])
    }

    @Test func skipsInjectedAndMetaText() {
        let h = history([
            user("u0", parent: nil, text: "<system-reminder>noise</system-reminder>", meta: true),
            user("u1", parent: "u0", text: "<command-name>/model</command-name>"),
            user("u2", parent: "u1", text: "Real question"),
            thinking("a0", parent: "u2", text: ""),
            assistantText("a1", parent: "a0", text: "Answer"),
            user("u3", parent: "a1", text: "[Request interrupted by user]"),
        ])
        #expect(texts(h.items) == ["user: /model", "user: Real question", "claude: Answer", "notice: Interrupted."])
    }

    /// Wrappers share a text block with what the user typed; strip them,
    /// don't drop the turn. Pasted content is the user's and stays.
    @Test func stripsInjectedWrappersButKeepsTheTurn() {
        let h = history([
            user("u1", parent: nil, text: "<pasted_content id=\"cc4c\">\nGaps list\n</pasted_content id=\"cc4c\">\n\nfix those gaps"),
            assistantText("a1", parent: "u1", text: "On it."),
            user("u2", parent: "a1", text: "<browser_instruction># Chrome\nrules</browser_instruction>run build and test success"),
            assistantText("a2", parent: "u2", text: "Running."),
            user("u3", parent: "a2", text: "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>"),
            user("u4", parent: "u3", text: "<local-command-stdout>Set model to Opus</local-command-stdout>"),
            user("u5", parent: "u4", text: "<div> renders twice — why?"),
        ])
        #expect(texts(h.items) == [
            "user: Gaps list\n\nfix those gaps",
            "claude: On it.",
            "user: run build and test success",
            "claude: Running.",
            "user: /model opus",
            "user: <div> renders twice — why?",
        ])
    }

    @Test func visibleUserTextHandlesBareWrappers() {
        #expect(ClaudeSessionStore.visibleUserText("<system-reminder>x</system-reminder>") == nil)
        #expect(ClaudeSessionStore.visibleUserText("<bash-input>ls -la</bash-input>") == "! ls -la")
        #expect(ClaudeSessionStore.visibleUserText("  plain  ") == "plain")
        #expect(ClaudeSessionStore.visibleUserText("<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n</task-notification>") == nil)
        #expect(ClaudeSessionStore.visibleUserText("<ide_opened_file>The user opened a.ts</ide_opened_file>why is this slow?") == "why is this slow?")
        // Markup the user pasted is theirs.
        #expect(ClaudeSessionStore.visibleUserText("<isif condition=\"${x}\"> breaks") == "<isif condition=\"${x}\"> breaks")
    }

    @Test func ignoresRequestBlobsAndBookkeeping() {
        let h = history([
            user("u1", parent: nil, text: "Hi"),
            #"{"type":"api-request-blob","message":{"role":"assistant","content":[{"type":"text","text":"not shown"}]}}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"x"}"#,
            assistantText("a1", parent: "u1", text: "Hello"),
        ])
        #expect(texts(h.items) == ["user: Hi", "claude: Hello"])
    }

    @Test func marksCallsWithoutAResultAsUnfinished() {
        let h = history([
            user("u1", parent: nil, text: "Run it"),
            toolUse("a1", parent: "u1", id: "t1", name: "Bash"),
        ])
        #expect(h.items.last?.toolCall?.status == .failed)
        #expect(h.items.last?.toolCall?.resultText.contains("No result recorded") == true)
    }

    @Test func failedCallsStayFailed() {
        let h = history([
            user("u1", parent: nil, text: "Run it"),
            toolUse("a1", parent: "u1", id: "t1", name: "Bash"),
            toolResult("u2", parent: "a1", id: "t1", text: "exit 1", error: true),
        ])
        #expect(h.items.last?.toolCall?.status == .failed)
        #expect(h.items.last?.toolCall?.isError == true)
    }

    /// Athena sends `@` mentions first and an "Attached files:" list last;
    /// a reloaded turn shows the prose with chips, as it did when sent.
    @Test func restoresAthenaMentionsAndAttachments() {
        let payload = "@src/app.ts @src/cart.ts#L3-9\n\nWhy does checkout fail?\n\nAttached files:\n- /tmp/shot.png"
        let h = history([user("u1", parent: nil, text: payload)])
        guard case .user(let text, let attachments, let contexts)? = h.items.first?.kind else {
            Issue.record("expected a user row"); return
        }
        #expect(text == "Why does checkout fail?")
        #expect(attachments.map(\.url.path) == ["/tmp/shot.png"])
        #expect(contexts.map(\.label) == ["app.ts", "cart.ts:3-9"])
        #expect(contexts.first?.url.path == "/p/src/app.ts")
    }

    @Test func proseThatMerelyStartsWithAnAtSignIsKept() {
        let h = history([user("u1", parent: nil, text: "@channel please review")])
        #expect(texts(h.items) == ["user: @channel please review"])
    }

    @Test func keepsOnlyTheMostRecentRows() {
        var lines = [user("u0", parent: nil, text: "start")]
        var parent = "u0"
        for i in 1...10 {
            lines.append(assistantText("a\(i)", parent: parent, text: "reply \(i)"))
            parent = "a\(i)"
        }
        let h = history(lines, limit: 4)
        #expect(h.omitted == 7)
        #expect(texts(h.items) == ["claude: reply 7", "claude: reply 8", "claude: reply 9", "claude: reply 10"])
    }

    @Test func emptyOrUnreadableTranscriptsGiveNothing() {
        #expect(history([]).items.isEmpty)
        #expect(history(["not json", "{"]).items.isEmpty)
    }

    /// End to end through the store: the file is found by session id.
    @Test func storeFindsTheTranscriptBySessionId() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "athena-history-\(UUID().uuidString)")
        let workspace = URL(fileURLWithPath: "/Users/dev/shop")
        let project = root.appending(path: "projects").appending(path: ClaudeSessionStore.escapedDirectoryName(for: workspace))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "44444444-4444-4444-4444-444444444444"
        try [user("u1", parent: nil, text: "Add dark mode"), assistantText("a1", parent: "u1", text: "Added.")]
            .joined(separator: "\n")
            .write(to: project.appending(path: "\(id).jsonl"), atomically: true, encoding: .utf8)

        let account = ClaudeAccount(id: "test", name: "Test", binaryName: "claude", configDirectory: root.path)
        let store = ClaudeSessionStore()
        let found = await store.history(sessionId: id, workspace: workspace, account: account)
        #expect(texts(found.items) == ["user: Add dark mode", "claude: Added."])
        let missing = await store.history(sessionId: "nope", workspace: workspace, account: account)
        #expect(missing.items.isEmpty)
    }
}

// MARK: - Resuming through AppState

/// Drives `AppState.resumeClaudeSession` for real: the async load, the
/// generation guard, and merging with rows that arrive meanwhile. The
/// account points at a binary that doesn't exist, so no agent is launched.
@MainActor
@Suite("Claude resume shows history", .serialized)
struct ClaudeResumeHistoryTests {

    private func makeAccount(sessionId: String) throws -> (URL, ClaudeAccount) {
        let root = FileManager.default.temporaryDirectory.appending(path: "athena-resume-\(UUID().uuidString)")
        let project = root.appending(path: "projects/-tmp-shop")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let lines = [
            #"{"parentUuid":null,"type":"user","message":{"role":"user","content":[{"type":"text","text":"Add dark mode"}]},"uuid":"u1","timestamp":"2026-11-02T20:00:00.000Z"}"#,
            #"{"parentUuid":"u1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Added a dark theme."}]},"uuid":"a1","timestamp":"2026-11-02T20:00:05.000Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: project.appending(path: "\(sessionId).jsonl"), atomically: true, encoding: .utf8)
        let account = ClaudeAccount(id: "test", name: "Test", binaryName: "athena-test-no-such-claude", configDirectory: root.path)
        return (root, account)
    }

    private func waitFor(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline {
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(20)))
        }
    }

    private func isUser(_ item: ClaudeTimelineItem, _ text: String) -> Bool {
        if case .user(let t, _, _) = item.kind { return t == text }
        return false
    }

    @Test func resumingShowsTheEarlierTurns() async throws {
        let id = "55555555-5555-5555-5555-555555555555"
        let (root, account) = try makeAccount(sessionId: id)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState()
        state.activeClaudeAccount = account
        state.resumeClaudeSession(ClaudeStoredSession(id: id, cwd: "/tmp/shop", title: "Add dark mode", modifiedAt: .now))
        #expect(state.claudeIsLoadingHistory)

        await waitFor { !state.claudeIsLoadingHistory }
        #expect(state.claudeIsLoadingHistory == false)
        let timeline = state.claudeTimeline
        #expect(timeline.count >= 3)
        #expect(isUser(timeline[0], "Add dark mode"))
        if case .assistant(let text, let streaming) = timeline[1].kind {
            #expect(text == "Added a dark theme.")
            #expect(streaming == false)
        } else {
            Issue.record("expected the assistant reply second, got \(timeline[1].kind)")
        }
        guard case .notice(let text, .info) = timeline[2].kind else {
            Issue.record("expected the resumed notice third"); return
        }
        #expect(text == "Resumed “Add dark mode”.")
    }

    /// Starting another conversation while the old one loads must not pour
    /// the old turns into the new one.
    @Test func aNewConversationDiscardsAStaleLoad() async throws {
        let id = "66666666-6666-6666-6666-666666666666"
        let (root, account) = try makeAccount(sessionId: id)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState()
        state.activeClaudeAccount = account
        state.resumeClaudeSession(ClaudeStoredSession(id: id, cwd: "/tmp/shop", title: "Add dark mode", modifiedAt: .now))
        state.newClaudeConversation()
        #expect(state.claudeIsLoadingHistory == false)

        let clock = ContinuousClock()
        try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(300)))
        #expect(!state.claudeTimeline.contains { isUser($0, "Add dark mode") })
    }
}
