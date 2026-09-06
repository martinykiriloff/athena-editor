// InlineCompletionService.swift
// Athena — cloud/local LLM backends for AI ghost-text inline completion.
// Swift 6, strict concurrency.

import Foundation

/// One inline-completion request's outcome: `text` is the cleaned suggestion
/// (nil when there's nothing usable), `statusMessage` is set only on a real
/// connectivity/server error worth surfacing to the user — not on a debounce
/// cancellation or an empty-but-successful response.
struct InlineCompletionResult: Sendable {
    var text: String?
    var statusMessage: String?

    static let empty = InlineCompletionResult(text: nil, statusMessage: nil)
}

// MARK: - InlineCompletionService

actor InlineCompletionService {

    // MARK: State

    /// `(endpoint, model)` pairs — joined as `"endpoint|model"` — that
    /// rejected Ollama's fill-in-middle `suffix` field at least once this
    /// session, so later requests skip straight to prompt-only instead of
    /// re-discovering the same failure on every keystroke.
    private var suffixUnsupported: Set<String> = []

    // MARK: - Claude (cloud)

    /// Calls claude-haiku for a short inline code completion at the cursor.
    /// Returns `nil` when the request fails — matches the pre-extraction
    /// behavior (Claude ghost text has never surfaced its own errors here).
    func requestClaude(prefix: String, suffix: String, apiKey: String) async -> String? {
        guard !apiKey.isEmpty else { return nil }

        let context = String(prefix.suffix(600)) + "<CURSOR>" + String(suffix.prefix(200))
        let body: [String: Any] = [
            "model":      "claude-haiku-4-5-20251001",
            "max_tokens": 80,
            "system":     "You are a code completion engine. Output ONLY the text that should appear at <CURSOR>. No explanation, no markdown, no backticks. Complete at most one line.",
            "messages":   [["role": "user", "content": context]],
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,               forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",         forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 10
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        guard
            let (respData, _) = try? await URLSession.shared.data(for: req),
            let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String,
            !text.isEmpty
        else { return nil }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ollama (local)

    /// Requests a completion from Ollama's native `/api/generate`, using
    /// real fill-in-middle (`prompt` + `suffix`) when the `(endpoint, model)`
    /// pair hasn't already told us it rejects `suffix` — some instruct
    /// models ("does not support insert") only accept prompt-only. On a
    /// first-time rejection, falls back to prompt-only within the same call
    /// (so this request still returns a usable suggestion) and remembers the
    /// fallback for the rest of the session.
    func requestOllama(
        prefix: String,
        suffix: String,
        contextHeader: String,
        endpoint: String,
        model: String,
        temperature: Double,
        maxTokens: Int
    ) async -> InlineCompletionResult {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/api/generate") else { return .empty }

        let promptHead = contextHeader + String(prefix.suffix(2000))
        let suffixTail = String(suffix.prefix(500))
        let cacheKey   = "\(endpoint)|\(model)"
        let trySuffix  = !suffixTail.isEmpty && !suffixUnsupported.contains(cacheKey)

        func body(includeSuffix: Bool) -> [String: Any] {
            var b: [String: Any] = [
                "model":  model,
                "prompt": promptHead,
                "stream": false,
                "options": [
                    "temperature": temperature,
                    "num_predict": maxTokens,
                ],
            ]
            if includeSuffix { b["suffix"] = suffixTail }
            return b
        }

        func send(includeSuffix: Bool) async throws -> (Data, URLResponse) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 20
            req.httpBody = try JSONSerialization.data(withJSONObject: body(includeSuffix: includeSuffix))
            return try await Self.dataWithConnectionRetry(for: req)
        }

        do {
            var (respData, response) = try await send(includeSuffix: trySuffix)

            if trySuffix, let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let detail = String(data: respData, encoding: .utf8) ?? ""
                if detail.localizedCaseInsensitiveContains("suffix") || detail.localizedCaseInsensitiveContains("insert") {
                    suffixUnsupported.insert(cacheKey)
                    (respData, response) = try await send(includeSuffix: false)
                }
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let detail = String(data: respData, encoding: .utf8)?.prefix(200) ?? ""
                return InlineCompletionResult(text: nil, statusMessage: "Ollama error \(http.statusCode) (model \(model)): \(detail)")
            }

            guard
                let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                let text = json["response"] as? String
            else { return .empty }

            return InlineCompletionResult(text: Self.cleanInlineCompletion(text, prefix: promptHead), statusMessage: nil)
        } catch {
            // Every keystroke cancels the in-flight request and schedules a
            // new one for the updated cursor position (see EditorView's
            // ghostDebounce). If a request was already waiting on Ollama's
            // reply when the next keystroke landed, Swift's URLSession
            // async/await bridge cancels that in-flight task automatically,
            // surfacing as URLError.cancelled — routine debounce behavior,
            // not a connectivity failure. Don't scare the user with
            // "unreachable" for a request Athena itself tore down.
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return .empty
            }
            return InlineCompletionResult(text: nil, statusMessage: "Ollama unreachable at \(base): \(error.localizedDescription)")
        }
    }

    /// Fetches installed model names from Ollama's `GET /api/tags`, for the
    /// Settings "Fetch models" picker. Returns an empty array on any failure
    /// (Ollama not running yet, wrong endpoint, etc.) — callers fall back to
    /// the existing free-text field.
    func fetchOllamaModels(endpoint: String) async -> [String] {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/api/tags") else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5

        guard
            let (data, response) = try? await URLSession.shared.data(for: req),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else { return [] }

        return models.compactMap { $0["name"] as? String }.sorted()
    }

    // MARK: - Generic OpenAI-compatible local server

    /// Requests a completion from any server speaking the OpenAI
    /// `/completions` shape (LM Studio, llama.cpp's `server`, vLLM, …) —
    /// `endpoint` is expected to already include the `/v1` prefix those
    /// servers use (e.g. `http://127.0.0.1:1234/v1`). Prompt-only: unlike
    /// Ollama's native API, `suffix`/fill-in-middle isn't standardized
    /// across OpenAI-compatible servers, so this always sends prompt-only.
    func requestOpenAICompatible(
        prefix: String,
        contextHeader: String,
        endpoint: String,
        model: String,
        apiKey: String,
        temperature: Double,
        maxTokens: Int
    ) async -> InlineCompletionResult {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/completions") else { return .empty }

        let promptHead = contextHeader + String(prefix.suffix(2000))
        let body: [String: Any] = [
            "model":       model,
            "prompt":      promptHead,
            "max_tokens":  maxTokens,
            "temperature": temperature,
            "stream":      false,
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Only set when non-empty — an empty bearer token would break servers
        // (llama.cpp's `server`, most local LM Studio setups) that don't
        // require auth at all and never expect the header to be present.
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 20
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .empty }
        req.httpBody = data

        do {
            let (respData, response) = try await Self.dataWithConnectionRetry(for: req)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let detail = String(data: respData, encoding: .utf8)?.prefix(200) ?? ""
                return InlineCompletionResult(text: nil, statusMessage: "Local model server error \(http.statusCode) (model \(model)): \(detail)")
            }

            guard
                let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let text = choices.first?["text"] as? String
            else { return .empty }

            return InlineCompletionResult(text: Self.cleanInlineCompletion(text, prefix: promptHead), statusMessage: nil)
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return .empty
            }
            return InlineCompletionResult(text: nil, statusMessage: "Local model server unreachable at \(base): \(error.localizedDescription)")
        }
    }

    // MARK: - Shared request/response helpers

    /// Performs `req` and retries on connection-level failures (host not yet
    /// listening, connection lost) that are typically transient — e.g. a
    /// local server still finishing startup. Does not retry HTTP error
    /// responses or other URL errors (those surface immediately).
    private static func dataWithConnectionRetry(
        for req: URLRequest,
        attempts: Int = 3,
        initialDelay: Duration = .milliseconds(300)
    ) async throws -> (Data, URLResponse) {
        var delay = initialDelay
        for _ in 1..<attempts {
            do {
                return try await URLSession.shared.data(for: req)
            } catch let error as URLError where Self.isTransientConnectionError(error) {
                // ContinuousClock, not Task.sleep(for:) — avoids a Swift 6.2
                // release-toolchain crash in swift_task_dealloc from colliding
                // cross-module Task.sleep(for:) specializations
                // (https://github.com/swiftlang/swift/issues/86204).
                let clock = ContinuousClock()
                try await clock.sleep(until: clock.now.advanced(by: delay))
                delay *= 2
            }
        }
        // Final attempt: let any error (transient or not) propagate to the caller.
        return try await URLSession.shared.data(for: req)
    }

    private static func isTransientConnectionError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .networkConnectionLost:
            return true
        default:
            return false
        }
    }

    /// Strips markdown fences and any echoed prefix from a raw model completion,
    /// returning `nil` when nothing usable remains. Instruct models like
    /// qwen3-coder reproduce the prompt before continuing it, so we cut the
    /// longest suffix of `prefix` that the response repeats at its head.
    private static func cleanInlineCompletion(_ raw: String, prefix: String) -> String? {
        var text = raw

        // Drop a leading ```lang fence and any trailing ``` fence.
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```") {
                text = String(text[..<fence.lowerBound])
            }
        }
        text = text.trimmingCharacters(in: .newlines)

        // Remove echoed prompt: find the longest suffix of `prefix` (up to 400
        // chars) that the response repeats at its start, and drop it.
        let maxOverlap = min(prefix.count, text.count, 400)
        if maxOverlap > 0 {
            for len in stride(from: maxOverlap, through: 1, by: -1) {
                if text.hasPrefix(String(prefix.suffix(len))) {
                    text = String(text.dropFirst(len))
                    break
                }
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
