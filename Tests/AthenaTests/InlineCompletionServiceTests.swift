// InlineCompletionServiceTests.swift
// Athena — context ranking, prompt building, output cleaning, and the
// streaming backends against recorded responses.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

// MARK: - Context ranking and file policy

@Suite("InlineContextRanker")
struct InlineContextRankerTests {
    @Test func secretsAreSensitive() {
        for path in ["/p/.env", "/p/.env.local", "/p/prod.env", "/home/me/.ssh/id_rsa", "/p/certs/server.pem",
                     "/p/key.p12", "/p/.npmrc", "/p/infra/prod.tfvars", "/p/credentials.json"] {
            #expect(InlineContextRanker.isSensitive(path: path), "\(path)")
        }
        for path in ["/p/src/app.ts", "/p/src/environment.ts", "/p/README.md", "/p/keyboard.swift"] {
            #expect(!InlineContextRanker.isSensitive(path: path), "\(path)")
        }
    }

    @Test func lockfilesAndBundlesAreNoise() {
        #expect(InlineContextRanker.isNoise(path: "/p/package-lock.json", length: 10))
        #expect(InlineContextRanker.isNoise(path: "/p/dist/app.min.js", length: 10))
        #expect(InlineContextRanker.isNoise(path: "/p/src/big.ts", length: 2_000_000))
        #expect(!InlineContextRanker.isNoise(path: "/p/src/app.ts", length: 2_000))
    }

    @Test func mostSimilarWindowWins() {
        let related = """
        export async function fetchUser(id: string): Promise<User> {
          const response = await api.get(`/users/${id}`)
          return response.data as User
        }
        """
        let unrelated = "body { color: red; margin: 0 }\n.header { padding: 4px }"
        let query = "const user = await fetchUser(id)\nconst response = await api"
        let result = InlineContextRanker.bestWindows(
            query: query,
            documents: [("styles.css", unrelated), ("api/user.ts", related)],
            maxChars: 2000
        )
        #expect(result.map(\.path) == ["api/user.ts"])
    }

    @Test func budgetIsRespected() {
        let doc = String(repeating: "alpha beta gamma delta\n", count: 30)
        let result = InlineContextRanker.bestWindows(
            query: "alpha beta gamma delta", documents: [("a.ts", doc)], maxChars: 50
        )
        #expect(result.isEmpty)
    }

    @Test func importSpecifiersSkipPackages() {
        let text = """
        import React from 'react'
        import { db } from "@/lib/db"
        import { User } from './models/user'
        const fs = require('fs')
        """
        #expect(InlineContextRanker.importSpecifiers(in: text) == ["@/lib/db", "./models/user"])
    }

    @Test func outlineKeepsSignaturesNotBodies() {
        let text = """
        export interface User {
          id: string
        }
        export function makeUser(id: string): User {
          return { id }
        }
        const internal = 1
        """
        let outline = InlineContextRanker.outline(of: text)
        #expect(outline.contains("export interface User"))
        #expect(outline.contains("export function makeUser(id: string): User"))
        #expect(!outline.contains("return { id }"))
    }

    @Test func identifiersNearCaretAreMostRecentFirst() {
        let prefix = "line one\nconst user = await fetchUser(userId)\nconst total = "
        let ids = InlineContextRanker.identifiersNearCaret(prefix: prefix, lines: 2, limit: 3)
        #expect(ids.map(\.name) == ["total", "userId", "fetchUser"])
        #expect(ids.first?.line == 3)
        #expect(ids.first?.column == 7)
    }
}

// MARK: - Prompt building

@Suite("InlinePromptBuilder")
struct InlinePromptBuilderTests {
    private func request(
        prefix: String = "function add(a, b) {\n  ",
        suffix: String = "\n}",
        mode: InlineCompletionMode = .endOfLine,
        snippets: [InlineContextSnippet] = [],
        header: String = "imports:\nimport x from './x'",
        language: Language = .typescript
    ) -> InlineCompletionRequest {
        InlineCompletionRequest(prefix: prefix, suffix: suffix, mode: mode, variant: 0,
                                path: "src/math.ts", language: language, header: header, snippets: snippets)
    }

    @Test func claudePromptMarksTheCaret() {
        let prompt = InlinePromptBuilder.claude(request())
        #expect(prompt.user.contains("function add(a, b) {\n  <CURSOR/>\n}"))
        #expect(prompt.user.contains("path=\"src/math.ts\""))
        #expect(!prompt.user.contains("<related_files>"))
        // Header only when the prefix window lost the top of the file.
        #expect(!prompt.user.contains("<file_header>"))
    }

    @Test func claudePromptIncludesRelatedFilesAndHeaderWhenTruncated() {
        let long = String(repeating: "// filler line\n", count: 400) + "const x = "
        let prompt = InlinePromptBuilder.claude(request(
            prefix: long, snippets: [InlineContextSnippet(path: "src/x.ts", text: "export const x = 1")]
        ))
        #expect(prompt.user.contains("<related_files>\n<file path=\"src/x.ts\">\nexport const x = 1\n</file>"))
        #expect(prompt.user.contains("<file_header>"))
    }

    @Test func claudeMidLineForbidsLineBreaks() {
        #expect(InlinePromptBuilder.claude(request(mode: .midLine)).system.contains("Never output a line break"))
    }

    @Test func qwenRawPromptUsesRepositoryFormat() {
        let prompt = InlinePromptBuilder.rawFIM(
            request(snippets: [InlineContextSnippet(path: "src/x.ts", text: "export const x = 1")]),
            family: .qwenCoder, repoName: "shop"
        )
        #expect(prompt == """
        <|repo_name|>shop
        <|file_sep|>src/x.ts
        export const x = 1
        <|file_sep|>src/math.ts
        <|fim_prefix|>function add(a, b) {
          <|fim_suffix|>
        }<|fim_middle|>
        """)
    }

    @Test func familyDetection() {
        #expect(InlinePromptBuilder.FIMFamily.detect(model: "qwen2.5-coder:7b") == .qwenCoder)
        #expect(InlinePromptBuilder.FIMFamily.detect(model: "qwen3:8b") == nil)
    }

    @Test func commentedPromptPutsContextInComments() {
        let result = InlinePromptBuilder.commentedPrompt(
            request(snippets: [InlineContextSnippet(path: "src/x.ts", text: "export const x = 1")])
        )
        #expect(result.prompt.hasPrefix("// Related code from src/x.ts:\n// export const x = 1\n"))
        #expect(result.prompt.hasSuffix("function add(a, b) {\n  "))
        #expect(result.suffix == "\n}")
    }

    @Test func languagesWithoutLineCommentsGetNoSnippets() {
        let result = InlinePromptBuilder.commentedPrompt(
            request(snippets: [InlineContextSnippet(path: "a.ts", text: "x")], language: .json)
        )
        #expect(!result.prompt.contains("Related code"))
    }
}

// MARK: - Cleaning output

@Suite("InlinePromptBuilder.clean")
struct InlineCleanTests {
    @Test func stripsThinkingAndFences() {
        let raw = "<think>\nthe user wants a sum\n</think>\n```ts\nreturn a + b\n```"
        #expect(InlinePromptBuilder.clean(raw, promptTail: "function add(a, b) {\n  ", final: true) == "return a + b")
    }

    @Test func waitsWhileStillThinking() {
        #expect(InlinePromptBuilder.clean("<think>hmm", promptTail: "x = ", final: false) == nil)
    }

    @Test func partialOutputWaitsUntilSettled() {
        #expect(InlinePromptBuilder.clean("ret", promptTail: "x\n  ", final: false) == nil)
        #expect(InlinePromptBuilder.clean("return a\n", promptTail: "x\n  ", final: false) == "return a")
        #expect(InlinePromptBuilder.clean("ret", promptTail: "x\n  ", final: true) == "ret")
    }

    @Test func dropsAnEchoedPrompt() {
        let tail = "function add(a, b) {\n  "
        #expect(InlinePromptBuilder.clean("function add(a, b) {\n  return a + b", promptTail: tail, final: true) == "return a + b")
    }

    @Test func keepsANewlineAfterRealCode() {
        // Caret right after "{": the suggestion legitimately starts a new line.
        #expect(InlinePromptBuilder.clean("\n  return a + b\n}", promptTail: "function add(a, b) {", final: true)
                == "\n  return a + b\n}")
    }

    @Test func dropsReTypedIndentationOnABlankLine() {
        #expect(InlinePromptBuilder.clean("  return a + b", promptTail: "{\n  ", final: true) == "return a + b")
        #expect(InlinePromptBuilder.clean("\n\nreturn 1", promptTail: "{\n  ", final: true) == "return 1")
    }

    @Test func stopsAtFIMTokens() {
        #expect(InlinePromptBuilder.clean("a + b<|endoftext|>junk", promptTail: "x = ", final: true) == "a + b")
    }
}

// MARK: - Service helpers

@Suite("InlineCompletionService helpers")
struct InlineCompletionServiceHelperTests {
    private func request(variant: Int = 0, prefix: String = "const x = ") -> InlineCompletionRequest {
        InlineCompletionRequest(prefix: prefix, suffix: "", mode: .endOfLine, variant: variant,
                                path: "a.ts", language: .typescript, header: "", snippets: [])
    }

    @Test func cacheKeyDependsOnTheRightThings() {
        let backend = InlineCompletionService.Backend.ollama(endpoint: "http://x", model: "m")
        let a = InlineCompletionService.cacheKey(request(), backend: backend)
        #expect(a == InlineCompletionService.cacheKey(request(), backend: backend))
        #expect(a != InlineCompletionService.cacheKey(request(variant: 1), backend: backend))
        #expect(a != InlineCompletionService.cacheKey(request(), backend: .ollama(endpoint: "http://x", model: "other")))
        // An edit far above the caret doesn't change the key.
        let far = String(repeating: "a", count: 3000)
        #expect(InlineCompletionService.cacheKey(request(prefix: far + String(repeating: "z", count: 1500)), backend: backend)
                == InlineCompletionService.cacheKey(request(prefix: "b" + far + String(repeating: "z", count: 1500)), backend: backend))
    }

    @Test func claudeCacheIDNeverContainsTheKey() {
        #expect(!InlineCompletionService.Backend.claude(apiKey: "sk-secret").cacheID.contains("sk-secret"))
    }

    @Test func errorMessageReadsJSONBodies() {
        #expect(InlineCompletionService.errorMessage(in: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#) == "slow down")
        #expect(InlineCompletionService.errorMessage(in: #"{"error":"model not found"}"#) == "model not found")
        #expect(InlineCompletionService.errorMessage(in: "plain text") == "plain text")
    }

    @Test func serverRootStripsV1() {
        #expect(InlineCompletionService.serverRoot("http://127.0.0.1:8080/v1") == "http://127.0.0.1:8080")
        #expect(InlineCompletionService.serverRoot("http://127.0.0.1:8080") == "http://127.0.0.1:8080")
    }

    @Test func dayStampIsLocalCalendarDay() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 7; components.hour = 12
        let date = Calendar.current.date(from: components)!
        #expect(AppState.dayStamp(date) == "2026-03-07")
    }
}

// MARK: - Streaming against recorded responses

/// Serves canned responses for the fake hosts (and a fake Claude key) only,
/// so real traffic from other tests is never intercepted.
final class InlineMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Canned: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: String
    }

    nonisolated(unsafe) static var responses: [String: Canned] = [:]
    nonisolated(unsafe) static var requestCounts: [String: Int] = [:]
    nonisolated(unsafe) static var lastBodies: [String: [String: Any]] = [:]
    static let lock = NSLock()

    static func key(for request: URLRequest) -> String? {
        guard let url = request.url, let host = url.host else { return nil }
        if host == "api.anthropic.com" {
            return request.value(forHTTPHeaderField: "x-api-key") == "mock-key" ? "claude\(url.path)" : nil
        }
        return host.hasSuffix(".mock.test") ? "\(host)\(url.path)" : nil
    }

    override class func canInit(with request: URLRequest) -> Bool { key(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = Self.key(for: request) ?? ""
        Self.lock.lock()
        let canned = Self.responses[key] ?? Canned(status: 404, body: "not found")
        Self.requestCounts[key, default: 0] += 1
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBodies[key] = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1",
                                       headerFields: canned.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(canned.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func set(_ key: String, _ canned: Canned) {
        lock.lock(); responses[key] = canned; lock.unlock()
    }

    static func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCounts[key] ?? 0
    }

    static func body(_ key: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return lastBodies[key]
    }
}

@Suite("InlineCompletionService streaming", .serialized)
struct InlineCompletionStreamingTests {
    init() { URLProtocol.registerClass(InlineMockURLProtocol.self) }

    private func request(prefix: String = "function add(a, b) {\n  ", variant: Int = 0) -> InlineCompletionRequest {
        InlineCompletionRequest(prefix: prefix, suffix: "\n}", mode: .endOfLine, variant: variant,
                                path: "src/math.ts", language: .typescript, header: "", snippets: [])
    }

    private func collect(_ stream: AsyncStream<InlineCompletionEvent>) async -> [InlineCompletionEvent] {
        var events: [InlineCompletionEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func ollamaStreamsAndCaches() async {
        let host = "ollama1.mock.test"
        InlineMockURLProtocol.set("\(host)/api/show", .init(status: 200, body: #"{"capabilities":["completion","insert"],"template":"{{ .Suffix }}"}"#))
        InlineMockURLProtocol.set("\(host)/api/generate", .init(status: 200, body: """
        {"response":"return a","done":false}
        {"response":" + b\\n","done":false}
        {"response":"","done":true}

        """))
        let service = InlineCompletionService()
        let config = InlineCompletionService.Config(
            backend: .ollama(endpoint: "http://\(host)", model: "codellama:7b-code"),
            temperature: 0.1, maxTokens: 64, repoName: "shop"
        )
        let events = await collect(service.stream(request(), config: config))
        #expect(events.contains(.text("return a + b")))
        #expect(events.last == .finished("return a + b"))

        let sent = InlineMockURLProtocol.body("\(host)/api/generate")
        #expect(sent?["suffix"] as? String == "\n}")
        #expect(sent?["think"] == nil)

        // Same position again: served from the cache, no second request.
        let again = await collect(service.stream(request(), config: config))
        #expect(again == [.finished("return a + b")])
        #expect(InlineMockURLProtocol.count("\(host)/api/generate") == 1)
    }

    @Test func qwenCoderUsesRawFIMAndThinkingModelsTurnItOff() async {
        let host = "ollama2.mock.test"
        InlineMockURLProtocol.set("\(host)/api/show", .init(status: 200, body: #"{"capabilities":["completion","insert","thinking"]}"#))
        InlineMockURLProtocol.set("\(host)/api/generate", .init(status: 200, body: #"{"response":"return a + b","done":true}"# + "\n"))
        let service = InlineCompletionService()
        let config = InlineCompletionService.Config(
            backend: .ollama(endpoint: "http://\(host)", model: "qwen2.5-coder:7b"),
            temperature: 0.1, maxTokens: 64, repoName: "shop"
        )
        _ = await collect(service.stream(request(), config: config))
        let sent = InlineMockURLProtocol.body("\(host)/api/generate")
        #expect(sent?["raw"] as? Bool == true)
        #expect(sent?["think"] as? Bool == false)
        #expect((sent?["prompt"] as? String)?.hasPrefix("<|repo_name|>shop\n") == true)
        #expect(sent?["suffix"] == nil)
    }

    @Test func modelWithoutInsertGetsNoSuffix() async {
        let host = "ollama3.mock.test"
        InlineMockURLProtocol.set("\(host)/api/show", .init(status: 200, body: #"{"capabilities":["completion"]}"#))
        InlineMockURLProtocol.set("\(host)/api/generate", .init(status: 200, body: #"{"response":"return a + b","done":true}"# + "\n"))
        let service = InlineCompletionService()
        let caps = await service.ollamaCapabilities(endpoint: "http://\(host)", model: "llama3:8b")
        #expect(caps == .init(insert: false, thinking: false))
        let config = InlineCompletionService.Config(
            backend: .ollama(endpoint: "http://\(host)", model: "llama3:8b"),
            temperature: 0.1, maxTokens: 64, repoName: "shop"
        )
        _ = await collect(service.stream(request(), config: config))
        #expect(InlineMockURLProtocol.body("\(host)/api/generate")?["suffix"] == nil)
    }

    @Test func claudeStreamsTextDeltas() async {
        InlineMockURLProtocol.set("claude/v1/messages", .init(status: 200, body: """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"return a"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" + b;\\n"}}

        event: message_stop
        data: {"type":"message_stop"}

        """))
        let service = InlineCompletionService()
        let config = InlineCompletionService.Config(backend: .claude(apiKey: "mock-key"), temperature: 0.1, maxTokens: 96, repoName: "shop")
        let events = await collect(service.stream(request(prefix: "function sum(a, b) {\n  "), config: config))
        #expect(events.last == .finished("return a + b;"))

        let sent = InlineMockURLProtocol.body("claude/v1/messages")
        #expect(sent?["model"] as? String == "claude-haiku-5-5")
        #expect(sent?["stream"] as? Bool == true)
        #expect(sent?["temperature"] == nil)
        #expect((sent?["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }

    @Test func claudeRateLimitReportsRetryAfter() async {
        InlineMockURLProtocol.set("claude/v1/messages", .init(
            status: 429, headers: ["retry-after": "12"],
            body: #"{"type":"error","error":{"type":"rate_limit_error","message":"Number of requests has exceeded your rate limit"}}"#
        ))
        let service = InlineCompletionService()
        let config = InlineCompletionService.Config(backend: .claude(apiKey: "mock-key"), temperature: 0.1, maxTokens: 96, repoName: "shop")
        let before = Date()
        let events = await collect(service.stream(request(prefix: "let rateLimited = "), config: config))
        guard case .rateLimited(let until)? = events.first else {
            Issue.record("expected rateLimited first, got \(events)")
            return
        }
        #expect(until.timeIntervalSince(before) >= 11)
        #expect(events.contains(.failed("Claude error 429: Number of requests has exceeded your rate limit")))
        #expect(events.last == .finished(nil))
    }

    // Next-edit prediction shares the Claude mock, so it lives in this
    // serialized suite rather than one that could run alongside it.
    @Test func claudeAnswerBecomesACandidate() async {
        InlineMockURLProtocol.set("claude/v1/messages", .init(status: 200, body: """
        {"content":[{"type":"text","text":"{\\"original\\": \\"getUser(2)\\", \\"replacement\\": \\"fetchUser(2)\\"}"}]}
        """))
        let service = InlineCompletionService()
        let query = NextEditQuery(excerpt: "const b = getUser(2)", excerptStartLine: 1, cursorLine: 1, edits: [])
        let result = await service.predictNextEdit(query, path: "a.ts", language: .typescript, apiKey: "mock-key")
        #expect(result == .candidate(NextEditCandidate(original: "getUser(2)", replacement: "fetchUser(2)")))
        let sent = InlineMockURLProtocol.body("claude/v1/messages")
        #expect(sent?["model"] as? String == "claude-haiku-5-5")
        #expect(sent?["stream"] == nil)
    }

    @Test func openAICompatibleFallsBackFromInfill() async {
        let host = "llama.mock.test"
        InlineMockURLProtocol.set("\(host)/infill", .init(status: 404, body: "Not Found"))
        InlineMockURLProtocol.set("\(host)/v1/completions", .init(status: 200, body: """
        data: {"choices":[{"text":"return a + b"}]}

        data: [DONE]

        """))
        let service = InlineCompletionService()
        let config = InlineCompletionService.Config(
            backend: .openAICompatible(endpoint: "http://\(host)/v1", model: "m", apiKey: ""),
            temperature: 0.1, maxTokens: 64, repoName: "shop"
        )
        let events = await collect(service.stream(request(prefix: "function mul(a, b) {\n  "), config: config))
        #expect(events.last == .finished("return a + b"))
        #expect(InlineMockURLProtocol.count("\(host)/infill") == 1)

        // /infill is remembered as missing.
        _ = await collect(service.stream(request(prefix: "function div(a, b) {\n  "), config: config))
        #expect(InlineMockURLProtocol.count("\(host)/infill") == 1)
    }

    @Test func llamaCppInfillSendsExtraFiles() async {
        let host = "infill.mock.test"
        InlineMockURLProtocol.set("\(host)/infill", .init(status: 200, body: """
        data: {"content":"return a - b","stop":false}

        data: {"content":"","stop":true}

        """))
        let service = InlineCompletionService()
        let config = InlineCompletionService.Config(
            backend: .openAICompatible(endpoint: "http://\(host)/v1", model: "m", apiKey: ""),
            temperature: 0.1, maxTokens: 64, repoName: "shop"
        )
        var req = request(prefix: "function sub(a, b) {\n  ")
        req.snippets = [InlineContextSnippet(path: "src/x.ts", text: "export const x = 1")]
        let events = await collect(service.stream(req, config: config))
        #expect(events.last == .finished("return a - b"))
        let extra = InlineMockURLProtocol.body("\(host)/infill")?["input_extra"] as? [[String: String]]
        #expect(extra == [["filename": "src/x.ts", "text": "export const x = 1"]])
    }
}

// MARK: - Next-edit prediction

@Suite("Next-edit prediction")
struct NextEditTests {
    @Test func parsesAnswerAndRejectsNoOps() {
        #expect(InlinePromptBuilder.parseNextEdit(#"{"original": "getUser(id)", "replacement": "fetchUser(id)"}"#)
                == NextEditCandidate(original: "getUser(id)", replacement: "fetchUser(id)"))
        // Prose around the object is tolerated.
        #expect(InlinePromptBuilder.parseNextEdit("Here: {\"original\": \"a\", \"replacement\": \"b\"} done")?.replacement == "b")
        #expect(InlinePromptBuilder.parseNextEdit(#"{"none": true}"#) == nil)
        #expect(InlinePromptBuilder.parseNextEdit(#"{"original": "a", "replacement": "a"}"#) == nil)
        #expect(InlinePromptBuilder.parseNextEdit("no json") == nil)
    }

    @Test func promptListsRecentEdits() {
        let query = NextEditQuery(excerpt: "const a = getUser(1)\nconst b = getUser(2)", excerptStartLine: 10,
                                  cursorLine: 10, edits: [RecentEdit(line: 10, before: "const a = getUser(1)", after: "const a = fetchUser(1)")])
        let prompt = InlinePromptBuilder.nextEdit(query, path: "src/a.ts", language: .typescript)
        #expect(prompt.user.contains("first_line=\"10\""))
        #expect(prompt.user.contains("line 10:\n- const a = getUser(1)\n+ const a = fetchUser(1)"))
        #expect(prompt.system.contains("exactly once"))
    }

    @Test func locateNeedsAUniqueMatchAwayFromTheCaret() {
        let buffer = "const a = fetchUser(1)\nconst b = getUser(2)\n" as NSString
        let all = NSRange(location: 0, length: buffer.length)
        let candidate = NextEditCandidate(original: "getUser(2)", replacement: "fetchUser(2)")
        let range = NextEditDriver.locate(candidate, in: buffer, within: all, cursor: 5)
        #expect(range == buffer.range(of: "getUser(2)"))

        // Ambiguous: two occurrences.
        let twice = "getUser(2)\ngetUser(2)" as NSString
        #expect(NextEditDriver.locate(candidate, in: twice, within: NSRange(location: 0, length: twice.length), cursor: 0) == nil)
        // Caret inside the target: that's typing, not a next edit.
        let inside = buffer.range(of: "getUser(2)").location + 3
        #expect(NextEditDriver.locate(candidate, in: buffer, within: all, cursor: inside) == nil)
        // Outside the window: not found.
        #expect(NextEditDriver.locate(candidate, in: buffer, within: NSRange(location: 0, length: 10), cursor: 0) == nil)
    }

    @Test func lineHelpers() {
        let ns = "one\ntwo\nthree" as NSString
        #expect(NextEditDriver.lineNumber(at: 0, in: ns) == 1)
        #expect(NextEditDriver.lineNumber(at: 5, in: ns) == 2)
        #expect(NextEditDriver.location(ofLine: 3, in: ns) == 8)
        #expect(NextEditDriver.location(ofLine: 9, in: ns) == ns.length)
        #expect(NextEditDriver.lineText(at: 5, in: ns) == "two")
    }

    @Test func inlineSuggestionBindings() {
        let d = KeyBinding.vscodeDefaults
        #expect(d.first { $0.action == .triggerInlineSuggestion }?.combo == KeyCombo(key: "\\", option: true))
        #expect(d.first { $0.action == .acceptInlineSuggestionLine }?.combo == nil)
        #expect(KeyAction.triggerInlineSuggestion.rawValue == "editor.action.inlineSuggest.trigger")
        #expect(KeyAction.triggerNextEdit.category == "Editor")
    }
}
