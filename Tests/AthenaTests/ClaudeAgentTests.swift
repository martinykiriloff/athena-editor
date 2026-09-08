// ClaudeAgentTests.swift
// Athena — the Claude Code stream-json wire protocol, driven against frames
// captured from the real CLI.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

// MARK: - Helpers

private extension ClaudeStreamDecoder {
    /// Feeds several NDJSON lines and returns everything they produced.
    mutating func decodeAll(_ lines: [String]) -> [ClaudeAgentEvent] {
        lines.flatMap { decode(line: $0) }
    }
}

// MARK: - Session init

@Suite("Claude session init frame")
struct ClaudeSessionInitTests {

    /// Captured from `claude --print --output-format stream-json --verbose`.
    private let initLine = """
    {"type":"system","subtype":"init","cwd":"/Users/dev/shop","session_id":"2716862a-ed2c-4bec-b740-1dcc61dbb4d9","tools":["Read","Edit","Bash"],"mcp_servers":[{"name":"context7","status":"connected"},{"name":"figma","status":"needs-auth"}],"model":"claude-sonnet-5","permissionMode":"default","slash_commands":["clear","compact"],"agents":["Explore"],"claude_code_version":"2.1.263"}
    """

    @Test func readsTheSessionIdentityAndCapabilities() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: initLine)

        guard case .sessionInit(let info)? = events.first else {
            Issue.record("expected a sessionInit event, got \(events)")
            return
        }
        #expect(info.sessionId == "2716862a-ed2c-4bec-b740-1dcc61dbb4d9")
        #expect(info.model == "claude-sonnet-5")
        #expect(info.cwd == "/Users/dev/shop")
        #expect(info.tools == ["Read", "Edit", "Bash"])
        #expect(info.mcpServers.count == 2)
        #expect(info.mcpServers.first?.isConnected == true)
        #expect(info.mcpServers.last?.isConnected == false)
    }

    /// Hook lifecycle frames dominate the stream volume and must never reach
    /// the timeline.
    @Test func ignoresHookLifecycleNoise() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decodeAll([
            #"{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup"}"#,
            #"{"type":"system","subtype":"hook_response","hook_name":"SessionStart:startup","exit_code":0}"#,
        ])
        #expect(events.isEmpty)
    }
}

// MARK: - Text streaming

@Suite("Claude assistant text streaming")
struct ClaudeTextStreamTests {

    private let messageStart = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_01","role":"assistant","content":[]}}}"#

    /// Text events carry the whole block, not a delta, so a dropped or
    /// duplicated frame can never corrupt the rendered text.
    @Test func accumulatesDeltasIntoWholeBlockText() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decodeAll([
            messageStart,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hey there fri"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"end!"}}}"#,
        ])

        let texts = events.compactMap { event -> String? in
            guard case .textUpdated(_, let text, _) = event else { return nil }
            return text
        }
        #expect(texts == ["", "Hey there fri", "Hey there friend!"])
    }

    /// Every delta for one block must land on the same timeline row.
    @Test func keepsOneBlockIdAcrossItsDeltas() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decodeAll([
            messageStart,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a"}}}"#,
        ])
        let ids = Set(events.compactMap { event -> String? in
            guard case .textUpdated(let id, _, _) = event else { return nil }
            return id
        })
        #expect(ids.count == 1)
        #expect(ids.first == "msg_01#0")
    }

    /// Two blocks in one message are distinct rows — a thinking block
    /// followed by prose must not overwrite each other.
    @Test func separatesThinkingFromProse() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decodeAll([
            messageStart,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"hmm"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"answer"}}}"#,
        ])

        let thinking = events.compactMap { event -> String? in
            guard case .thinkingUpdated(let id, _, _) = event else { return nil }
            return id
        }
        let prose = events.compactMap { event -> String? in
            guard case .textUpdated(let id, _, _) = event else { return nil }
            return id
        }
        #expect(thinking == ["msg_01#0"])
        #expect(prose == ["msg_01#1"])
    }

    /// When partial streaming is unavailable, whole-block `assistant`
    /// snapshots have to carry the text instead — otherwise the panel would
    /// render an empty response.
    @Test func fallsBackToAssistantSnapshotsWithoutPartials() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: #"{"type":"assistant","uuid":"u1","message":{"id":"msg_01","role":"assistant","content":[{"type":"text","text":"Hello"}]}}"#)

        guard case .textUpdated(_, let text, _)? = events.first else {
            Issue.record("expected snapshot text, got \(events)")
            return
        }
        #expect(text == "Hello")
    }

    /// With partials present, the snapshot must NOT re-emit the same prose —
    /// that would duplicate the paragraph in the transcript.
    @Test func ignoresSnapshotTextOncePartialsAreSeen() {
        var decoder = ClaudeStreamDecoder()
        _ = decoder.decodeAll([
            messageStart,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hello"}}}"#,
        ])
        let events = decoder.decode(line: #"{"type":"assistant","uuid":"u1","message":{"id":"msg_01","role":"assistant","content":[{"type":"text","text":"Hello"}]}}"#)

        let texts = events.filter { if case .textUpdated = $0 { return true }; return false }
        #expect(texts.isEmpty)
    }
}

// MARK: - Tool calls

@Suite("Claude tool call streaming")
struct ClaudeToolStreamTests {

    private let toolFrames = [
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_02","role":"assistant","content":[]}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01","name":"Read","input":{}}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\": \"/et"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"c/hosts\"}"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#,
    ]

    @Test func reassemblesToolInputSplitAcrossDeltas() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decodeAll(toolFrames)

        guard case .toolStarted(let id, let name, _)? = events.first else {
            Issue.record("expected toolStarted, got \(events)")
            return
        }
        #expect(id == "toolu_01")
        #expect(name == "Read")

        let inputs = events.compactMap { event -> JSONValue? in
            guard case .toolInputUpdated(_, let input) = event else { return nil }
            return input
        }
        #expect(inputs.last?["file_path"]?.stringValue == "/etc/hosts")
    }

    /// A half-arrived JSON object must not produce a garbage input.
    @Test func emitsNothingForUnparsablePartialInput() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decodeAll(Array(toolFrames.prefix(3)))
        let inputs = events.filter { if case .toolInputUpdated = $0 { return true }; return false }
        #expect(inputs.isEmpty)
    }

    @Test func pairsToolResultsBackToTheirCall() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"hello-from-athena","is_error":false}]}}"#)

        guard case .toolResult(let id, let text, let isError)? = events.first else {
            Issue.record("expected toolResult, got \(events)")
            return
        }
        #expect(id == "toolu_01")
        #expect(text == "hello-from-athena")
        #expect(isError == false)
    }

    /// Tool results also arrive as content-block arrays rather than strings.
    @Test func flattensStructuredToolResultContent() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}]}}"#)

        guard case .toolResult(_, let text, _)? = events.first else {
            Issue.record("expected toolResult, got \(events)")
            return
        }
        #expect(text == "line one\nline two")
    }

    @Test func marksFailedToolResults() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"nope","is_error":true}]}}"#)

        guard case .toolResult(_, _, let isError)? = events.first else {
            Issue.record("expected toolResult, got \(events)")
            return
        }
        #expect(isError)
    }
}

// MARK: - Permissions

@Suite("Claude permission prompts")
struct ClaudePermissionTests {

    /// Captured from a real `can_use_tool` control request.
    private let requestLine = """
    {"type":"control_request","request_id":"06661029-c8b6","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"curl -s https://example.com","description":"Fetch example.com"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"curl -s https://example.com"}],"behavior":"allow","destination":"localSettings"}],"decision_reason":"This command requires approval","tool_use_id":"toolu_015d"}}
    """

    @Test func surfacesTheRequestWithItsToolInput() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: requestLine)

        guard case .permissionRequest(let request)? = events.first else {
            Issue.record("expected permissionRequest, got \(events)")
            return
        }
        #expect(request.id == "06661029-c8b6")
        #expect(request.toolName == "Bash")
        #expect(request.toolUseId == "toolu_015d")
        #expect(request.reason == "This command requires approval")
        #expect(request.input["command"]?.stringValue == "curl -s https://example.com")
    }

    /// The "always allow" button text comes from the CLI's own rule
    /// suggestion, so approving writes the rule the terminal would.
    @Test func labelsAlwaysAllowFromTheSuggestedRule() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: requestLine)

        guard case .permissionRequest(let request)? = events.first else {
            Issue.record("expected permissionRequest")
            return
        }
        #expect(request.suggestions.count == 1)
        #expect(request.suggestions.first?.label == "Always allow Bash(curl -s https://example.com)")
    }

    /// A tool auto-denied by the permission mode never raises a prompt — the
    /// panel has to learn about it from the `permission_denied` frame.
    @Test func reportsAutoDenials() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: #"{"type":"system","subtype":"permission_denied","tool_name":"Read","tool_use_id":"toolu_01","message":"Claude requested permissions to read from /etc/hosts."}"#)

        guard case .permissionDenied(let toolUseId, let reason)? = events.first else {
            Issue.record("expected permissionDenied, got \(events)")
            return
        }
        #expect(toolUseId == "toolu_01")
        #expect(reason.contains("/etc/hosts"))
    }
}

// MARK: - Turn results

@Suite("Claude turn results")
struct ClaudeTurnResultTests {

    @Test func readsCostAndUsage() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Done","duration_ms":5185,"total_cost_usd":0.100633,"num_turns":2,"usage":{"input_tokens":4,"output_tokens":106,"cache_read_input_tokens":81765,"cache_creation_input_tokens":20803}}"#)

        guard case .turnResult(let result)? = events.first else {
            Issue.record("expected turnResult, got \(events)")
            return
        }
        #expect(result.isError == false)
        #expect(result.text == "Done")
        #expect(result.durationMs == 5185)
        #expect(abs(result.costUSD - 0.100633) < 0.000001)
        #expect(result.outputTokens == 106)
        #expect(result.totalInputTokens == 4 + 81765 + 20803)
    }
}

// MARK: - Slash command catalogue

@Suite("Claude slash command discovery")
struct ClaudeSlashCommandTests {

    /// The command list is read from the live `initialize` handshake, so
    /// user skills and plugin commands appear without Athena hard-coding them.
    @Test func readsCommandsFromTheInitializeResponse() {
        var decoder = ClaudeStreamDecoder()
        let events = decoder.decode(line: #"{"type":"control_response","response":{"subtype":"success","request_id":"initialize","response":{"commands":[{"name":"commit","description":"Write a commit","argumentHint":""},{"name":"vercel:deploy","description":"Deploy","argumentHint":"[prod]"}]}}}"#)

        guard case .controlResponse(let requestId, let payload)? = events.first else {
            Issue.record("expected controlResponse, got \(events)")
            return
        }
        #expect(requestId == "initialize")

        let commands = ClaudeStreamDecoder.slashCommands(fromInitializePayload: payload)
        #expect(commands.count == 2)
        #expect(commands.first?.trigger == "/commit")
        #expect(commands.last?.argumentHint == "[prod]")
        // Plugin commands group under their namespace in the palette.
        #expect(commands.last?.group == "vercel")
        #expect(commands.first?.group == "Built-in")
    }
}

// MARK: - Tool presentation

@Suite("Claude tool presentation")
struct ClaudeToolPresentationTests {

    private func call(_ name: String, _ input: [String: JSONValue]) -> ClaudeToolCall {
        ClaudeToolCall(id: "t", name: name, input: .object(input))
    }

    @Test func summarisesEachToolByItsMostUsefulArgument() {
        #expect(call("Bash", ["command": .string("npm test"), "description": .string("Run tests")]).summary == "Run tests")
        #expect(call("Read", ["file_path": .string("/a/b/src/App.tsx")]).summary == "src/App.tsx")
        #expect(call("Grep", ["pattern": .string("TODO"), "glob": .string("*.ts")]).summary == "TODO in *.ts")
        #expect(call("WebFetch", ["url": .string("https://example.com")]).summary == "https://example.com")
    }

    /// A Bash command spanning several lines must not blow up the row height.
    @Test func collapsesMultiLineBashToItsFirstLine() {
        let summary = call("Bash", ["command": .string("set -e\nnpm ci\nnpm test")]).summary
        #expect(summary == "set -e")
    }

    @Test func rendersEditsAsADiff() {
        let detail = call("Edit", ["old_string": .string("let a = 1"), "new_string": .string("let a = 2")]).detail
        guard case .diff(let old, let new) = detail else {
            Issue.record("expected a diff detail, got \(detail)")
            return
        }
        #expect(old == "let a = 1")
        #expect(new == "let a = 2")
    }

    @Test func rendersTodoWriteAsAChecklist() {
        let todos = JSONValue.array([
            .object(["content": .string("Wire the decoder"), "status": .string("completed")]),
            .object(["content": .string("Build the panel"), "status": .string("in_progress")]),
        ])
        guard case .todos(let items) = call("TodoWrite", ["todos": todos]).detail else {
            Issue.record("expected todos detail")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].isDone)
        #expect(items[1].isInProgress)
    }

    /// MCP tool names are unreadable verbatim; the panel unpacks them.
    @Test func humanisesMCPToolNames() {
        #expect(call("mcp__GitKraken__git_status", [:]).displayName == "git_status (GitKraken)")
        #expect(call("mcp__GitKraken__git_status", [:]).icon == "puzzlepiece.extension")
    }

    @Test func flagsFileMutatingTools() {
        #expect(call("Edit", [:]).isMutating)
        #expect(call("Write", [:]).isMutating)
        #expect(!call("Read", [:]).isMutating)
        #expect(!call("Bash", [:]).isMutating)
    }
}

// MARK: - Launch configuration

@Suite("Claude agent launch")
struct ClaudeAgentLaunchTests {

    /// The panel depends on every one of these flags: without stream-json in
    /// both directions there is no tool timeline, and without the permission
    /// flags every prompt is auto-denied instead of asked.
    @Test func requestsTheBidirectionalStreamingProtocol() {
        let args = ClaudeAgentService.arguments(for: ClaudeAgentConfig())

        #expect(args.contains("--print"))
        #expect(argument(args, after: "--input-format") == "stream-json")
        #expect(argument(args, after: "--output-format") == "stream-json")
        #expect(args.contains("--include-partial-messages"))
        #expect(argument(args, after: "--permission-prompts") == "host")
        #expect(argument(args, after: "--permission-prompt-tool") == "stdio")
        #expect(argument(args, after: "--permission-mode") == "default")
    }

    @Test func passesModelAndResumeOnlyWhenSet() {
        var config = ClaudeAgentConfig()
        #expect(!ClaudeAgentService.arguments(for: config).contains("--model"))
        #expect(!ClaudeAgentService.arguments(for: config).contains("--resume"))

        config.model = .opus
        config.resumeSessionId = "abc-123"
        config.permissionMode = .plan
        let args = ClaudeAgentService.arguments(for: config)
        #expect(argument(args, after: "--model") == "opus")
        #expect(argument(args, after: "--resume") == "abc-123")
        #expect(argument(args, after: "--permission-mode") == "plan")
    }

    /// The work account is a second CLI config root, exactly like the
    /// `claude-work` shell wrapper — so Athena can skip the login shell.
    @Test func isolatesTheWorkAccountByConfigDirectory() {
        let personal = ClaudeAgentService.environment(
            for: ClaudeAgentConfig(account: .personal), extraPaths: []
        )
        #expect(personal["CLAUDE_CONFIG_DIR"] == nil)

        let work = ClaudeAgentService.environment(
            for: ClaudeAgentConfig(account: .work), extraPaths: []
        )
        #expect(work["CLAUDE_CONFIG_DIR"]?.hasSuffix("/.claude-work") == true)
    }

    /// Apps launched from Finder inherit a PATH without ~/.local/bin, which is
    /// where Claude Code installs by default.
    @Test func prependsCommonInstallLocationsToPath() {
        let env = ClaudeAgentService.environment(
            for: ClaudeAgentConfig(), extraPaths: ["/opt/tools/bin"]
        )
        #expect(env["PATH"]?.hasPrefix("/opt/tools/bin:") == true)
    }

    private func argument(_ args: [String], after flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

// MARK: - Context references

@Suite("Claude context references")
struct ClaudeContextRefTests {
    private let root = URL(fileURLWithPath: "/Users/dev/shop")

    /// `@path` mentions are resolved by the CLI itself, so they must be
    /// workspace-relative and use its line-range syntax.
    @Test func rendersWorkspaceRelativeMentions() {
        let file = ClaudeContextRef(url: root.appending(path: "src/api/route.ts"))
        #expect(file.promptFragment(relativeTo: root) == "@src/api/route.ts")

        let selection = ClaudeContextRef(
            url: root.appending(path: "src/api/route.ts"), lineRange: 10...24, kind: .selection
        )
        #expect(selection.promptFragment(relativeTo: root) == "@src/api/route.ts#L10-24")
        #expect(selection.label == "route.ts:10-24")
    }

    /// A file outside the workspace has no relative form — send it absolute
    /// rather than a path the agent would resolve against the wrong root.
    @Test func fallsBackToAbsolutePathsOutsideTheWorkspace() {
        let outside = ClaudeContextRef(url: URL(fileURLWithPath: "/etc/hosts"))
        #expect(outside.promptFragment(relativeTo: root) == "@/etc/hosts")
    }

    /// The same file attached twice must collapse to one chip.
    @Test func identifiesTheSameReferenceIdentically() {
        let a = ClaudeContextRef(url: root.appending(path: "a.ts"))
        let b = ClaudeContextRef(url: root.appending(path: "a.ts"))
        #expect(a.id == b.id)

        let ranged = ClaudeContextRef(url: root.appending(path: "a.ts"), lineRange: 1...2, kind: .selection)
        #expect(ranged.id != a.id)
    }
}

// MARK: - Live agent session

/// Drives `ClaudeAgentService` against the real `claude` CLI, the way
/// `DebuggerBackendTests` drives real debug adapters. Everything below the
/// decoder — process launch, pipe framing, the control handshake and the
/// actor's own isolation — only actually holds together at runtime.
///
/// Unlike the debugger's adapters, these turns cost real API usage and need a
/// signed-in CLI, so `ATHENA_SKIP_LIVE_CLAUDE_TESTS=1` turns the suite off for
/// a routine `make test` (or when offline or rate-limited).
@Suite(
    "Claude live agent session",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ATHENA_SKIP_LIVE_CLAUDE_TESTS"] == nil)
)
struct ClaudeLiveAgentTests {

    /// Skips rather than fails where Claude Code isn't installed.
    private var binaryAvailable: Bool {
        ClaudeAgentService.resolveBinary("claude", extraPaths: [
            "\(NSHomeDirectory())/.local/bin", "/usr/local/bin", "/opt/homebrew/bin",
        ]) != nil
    }

    private func makeConfig() -> ClaudeAgentConfig {
        var config = ClaudeAgentConfig()
        config.workingDirectory = FileManager.default.temporaryDirectory
        config.model = .haiku
        return config
    }

    /// Collects events until `isDone` or the deadline, then tears the session
    /// down. A hung child must fail the test, never hang the suite.
    private func drain(
        _ service: ClaudeAgentService,
        _ stream: AsyncStream<ClaudeAgentEvent>,
        timeout: Duration = .seconds(120),
        until isDone: @escaping @Sendable (ClaudeAgentEvent) -> Bool
    ) async -> [ClaudeAgentEvent] {
        let collected: [ClaudeAgentEvent] = await withTaskGroup(of: [ClaudeAgentEvent]?.self) { group in
            group.addTask {
                var events: [ClaudeAgentEvent] = []
                for await event in stream {
                    events.append(event)
                    if isDone(event) { break }
                }
                return events
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
        await service.stop()
        return collected
    }

    /// The whole pipeline: launch, handshake, a turn, and a clean result.
    @Test func streamsARealTurnEndToEnd() async throws {
        try #require(binaryAvailable, "claude CLI not installed")

        let service = ClaudeAgentService()
        let stream = try await service.start(config: makeConfig())
        await service.send(text: "Reply with exactly the word ATHENA and nothing else.")

        let events = await drain(service, stream) { event in
            if case .turnResult = event { return true }
            return false
        }

        // The init frame proves the process launched and spoke the protocol.
        let inits = events.compactMap { event -> ClaudeSessionInfo? in
            guard case .sessionInit(let info) = event else { return nil }
            return info
        }
        #expect(inits.count == 1)
        #expect(!(inits.first?.sessionId.isEmpty ?? true))
        #expect(!(inits.first?.tools.isEmpty ?? true))

        // Streaming text has to arrive through the partial-message path.
        let text = events.compactMap { event -> String? in
            guard case .textUpdated(_, let text, _) = event else { return nil }
            return text
        }.last ?? ""
        #expect(text.uppercased().contains("ATHENA"), "got: \(text)")

        guard case .turnResult(let result)? = events.last else {
            Issue.record("expected the turn to finish with a result, got \(String(describing: events.last))")
            return
        }
        #expect(!result.isError)
    }

    /// The `initialize` handshake is what populates the composer's `/` palette
    /// with this machine's real commands.
    @Test func discoversSlashCommandsFromTheHandshake() async throws {
        try #require(binaryAvailable, "claude CLI not installed")

        let service = ClaudeAgentService()
        let stream = try await service.start(config: makeConfig())

        let events = await drain(service, stream, timeout: .seconds(60)) { event in
            if case .controlResponse(let id, _) = event, id == "initialize" { return true }
            return false
        }

        guard case .controlResponse(_, let payload)? = events.last else {
            Issue.record("no initialize response arrived")
            return
        }
        let commands = ClaudeStreamDecoder.slashCommands(fromInitializePayload: payload)
        #expect(!commands.isEmpty)
        #expect(commands.contains { $0.name == "clear" })
    }

    /// A tool call must surface as a started/input/result triple — this is the
    /// timeline's entire content, and it crosses the pipe in many small frames.
    @Test func reportsToolCallsWithTheirResults() async throws {
        try #require(binaryAvailable, "claude CLI not installed")

        // A file the agent can read without needing any permission prompt.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "athena-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "marker.txt")
        try "athena-marker-value".write(to: file, atomically: true, encoding: .utf8)

        var config = makeConfig()
        config.workingDirectory = directory
        config.permissionMode = .acceptEdits

        let service = ClaudeAgentService()
        let stream = try await service.start(config: config)
        await service.send(text: "Read the file marker.txt in the current directory and tell me what it contains.")

        let events = await drain(service, stream) { event in
            if case .turnResult = event { return true }
            return false
        }

        let started = events.compactMap { event -> String? in
            guard case .toolStarted(let id, let name, _) = event, name == "Read" else { return nil }
            return id
        }
        #expect(!started.isEmpty, "expected a Read tool call")

        guard let toolId = started.first else { return }

        let inputs = events.compactMap { event -> JSONValue? in
            guard case .toolInputUpdated(let id, let input) = event, id == toolId else { return nil }
            return input
        }
        #expect(inputs.last?["file_path"]?.stringValue?.hasSuffix("marker.txt") == true)

        let results = events.compactMap { event -> String? in
            guard case .toolResult(let id, let text, _) = event, id == toolId else { return nil }
            return text
        }
        #expect(results.first?.contains("athena-marker-value") == true)
    }

    /// After an interrupt the turn must still close out with a result. This
    /// is the property Stop actually depends on: if the CLI answered an
    /// interrupt by going silent, `claudeIsStreaming` would never clear and
    /// the composer would stay wedged in the stop state forever.
    @Test func aTurnStillCompletesAfterAnInterrupt() async throws {
        try #require(binaryAvailable, "claude CLI not installed")

        let service = ClaudeAgentService()
        let stream = try await service.start(config: makeConfig())
        await service.send(text: "Count slowly from 1 to 500, one number per line, with no other text.")

        // Interrupt as soon as the model starts producing output.
        let interrupter = Task {
            try? await ContinuousClock().sleep(for: .seconds(12))
            await service.interrupt()
        }
        defer { interrupter.cancel() }

        let events = await drain(service, stream, timeout: .seconds(90)) { event in
            if case .turnResult = event { return true }
            return false
        }

        guard case .turnResult? = events.last else {
            Issue.record("the interrupted turn never produced a result")
            return
        }
        // The session process must survive an interrupt — Stop ends the turn,
        // not the conversation.
        #expect(events.contains { if case .sessionInit = $0 { return true }; return false })
    }
}

// MARK: - Session history

/// Reads the CLI's own transcript store, so the panel's history list matches
/// what `claude --resume` would offer.
@Suite("Claude session history")
struct ClaudeSessionStoreTests {

    /// Builds a fake `~/.claude/projects` tree in a temp directory.
    private func makeStore(cwd: String, transcripts: [(id: String, lines: [String])]) throws -> (URL, ClaudeAccount) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "athena-claude-store-\(UUID().uuidString)")
        let project = root.appending(path: "projects/-fake-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        for transcript in transcripts {
            let file = project.appending(path: "\(transcript.id).jsonl")
            try transcript.lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        return (root, ClaudeAccount(
            id: "test", name: "Test", binaryName: "claude", configDirectory: root.path
        ))
    }

    @Test func titlesSessionsByTheirOpeningPrompt() async throws {
        let cwd = "/Users/dev/shop"
        let (root, account) = try makeStore(cwd: cwd, transcripts: [
            (id: "11111111-1111-1111-1111-111111111111", lines: [
                #"{"type":"summary","cwd":"\#(cwd)"}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the checkout bug"}]},"cwd":"\#(cwd)"}"#,
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ClaudeSessionStore()
        let sessions = await store.recentSessions(
            workspace: URL(fileURLWithPath: cwd), account: account
        )

        #expect(sessions.count == 1)
        #expect(sessions.first?.id == "11111111-1111-1111-1111-111111111111")
        #expect(sessions.first?.displayTitle == "Fix the checkout bug")
    }

    /// Transcripts rooted elsewhere must not leak into this workspace's list.
    @Test func excludesConversationsFromOtherWorkspaces() async throws {
        let cwd = "/Users/dev/shop"
        let (root, account) = try makeStore(cwd: cwd, transcripts: [
            (id: "22222222-2222-2222-2222-222222222222", lines: [
                #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Elsewhere"}]},"cwd":"/Users/dev/other"}"#,
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ClaudeSessionStore()
        let sessions = await store.recentSessions(
            workspace: URL(fileURLWithPath: cwd), account: account
        )
        #expect(sessions.isEmpty)
    }

    /// The opening turn is often a tool result or an injected `<...>` block;
    /// titling on those would fill the menu with machine text.
    @Test func skipsMetaAndToolTurnsWhenTitling() async throws {
        let cwd = "/Users/dev/shop"
        let (root, account) = try makeStore(cwd: cwd, transcripts: [
            (id: "33333333-3333-3333-3333-333333333333", lines: [
                #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>noise</system-reminder>"},"cwd":"\#(cwd)"}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<command-name>/clear</command-name>"}]},"cwd":"\#(cwd)"}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Add a dark theme"}]},"cwd":"\#(cwd)"}"#,
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ClaudeSessionStore()
        let sessions = await store.recentSessions(
            workspace: URL(fileURLWithPath: cwd), account: account
        )
        #expect(sessions.first?.displayTitle == "Add a dark theme")
    }

    /// A conversation with no readable prompt still has to be selectable.
    @Test func namesUntitledConversations() {
        let session = ClaudeStoredSession(id: "x", cwd: "/a", title: "  ", modifiedAt: .now)
        #expect(session.displayTitle == "Untitled conversation")
    }

    /// The CLI's project folder is the working directory with its separators
    /// flattened — matched first, with a scan as the fallback.
    @Test func derivesTheProjectFolderName() {
        #expect(
            ClaudeSessionStore.escapedDirectoryName(for: URL(fileURLWithPath: "/Users/dev/shop"))
                == "-Users-dev-shop"
        )
    }
}
