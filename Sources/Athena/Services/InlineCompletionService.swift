// InlineCompletionService.swift
// Athena — cloud/local LLM backends for AI ghost-text inline completion:
// streaming requests, a result cache, and per-model capability discovery.
// Swift 6, strict concurrency.

import Foundation

// MARK: - InlineCompletionService

actor InlineCompletionService {

    // MARK: Configuration

    enum Backend: Sendable, Equatable {
        case claude(apiKey: String)
        case ollama(endpoint: String, model: String)
        case openAICompatible(endpoint: String, model: String, apiKey: String)

        /// Identifies the model for cache keys (never includes a key).
        var cacheID: String {
            switch self {
            case .claude:                                 return "claude|\(InlineCompletionService.claudeModel)"
            case .ollama(let endpoint, let model):        return "ollama|\(endpoint)|\(model)"
            case .openAICompatible(let endpoint, let model, _): return "oai|\(endpoint)|\(model)"
            }
        }
    }

    struct Config: Sendable, Equatable {
        var backend: Backend
        var temperature: Double
        var maxTokens: Int
        /// Used in Qwen's repository prompt (`<|repo_name|>`).
        var repoName: String
    }

    /// What `/api/show` says a local Ollama model can do.
    struct OllamaCapabilities: Sendable, Equatable {
        /// Accepts `suffix` (real fill-in-middle).
        var insert: Bool
        /// A thinking model — send `think: false` for completions.
        var thinking: Bool
    }

    static let claudeModel = "claude-haiku-5-5"

    // MARK: State

    /// Finished suggestions by request fingerprint. Only complete,
    /// uncancelled answers are stored, so a cached hit is always whole.
    private var cache: [Int: String] = [:]
    private var cacheOrder: [Int] = []
    private static let cacheLimit = 128

    private var capabilities: [String: OllamaCapabilities] = [:]
    /// `endpoint|model` pairs that rejected `suffix` at least once.
    private var suffixUnsupported: Set<String> = []
    /// OpenAI-compatible endpoints without llama.cpp's `/infill`.
    private var infillUnsupported: Set<String> = []

    // MARK: - Streaming

    /// A finished suggestion for this request, if one is cached.
    func cachedSuggestion(for request: InlineCompletionRequest, backend: Backend) -> String? {
        cache[Self.cacheKey(request, backend: backend)]
    }

    /// Streams one suggestion. Cancelling the consumer (or dropping the
    /// stream) cancels the network request.
    nonisolated func stream(_ request: InlineCompletionRequest, config: Config) -> AsyncStream<InlineCompletionEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(request, config: config, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: InlineCompletionRequest,
        config: Config,
        continuation: AsyncStream<InlineCompletionEvent>.Continuation
    ) async {
        let key = Self.cacheKey(request, backend: config.backend)
        if let hit = cache[key] {
            continuation.yield(.finished(hit))
            return
        }

        let outcome: Outcome
        switch config.backend {
        case .claude(let apiKey):
            outcome = await runClaude(request, apiKey: apiKey, config: config, continuation: continuation)
        case .ollama(let endpoint, let model):
            outcome = await runOllama(request, endpoint: endpoint, model: model, config: config, continuation: continuation)
        case .openAICompatible(let endpoint, let model, let apiKey):
            outcome = await runOpenAICompatible(request, endpoint: endpoint, model: model, apiKey: apiKey,
                                                config: config, continuation: continuation)
        }

        switch outcome {
        case .finished(let text):
            if let text, !Task.isCancelled { store(text, for: key) }
            continuation.yield(.finished(text))
        case .failed(let message):
            continuation.yield(.failed(message))
            continuation.yield(.finished(nil))
        case .rateLimited(let until, let message):
            continuation.yield(.rateLimited(until: until))
            continuation.yield(.failed(message))
            continuation.yield(.finished(nil))
        case .cancelled:
            break
        }
    }

    private enum Outcome {
        case finished(String?)
        case failed(String)
        case rateLimited(until: Date, message: String)
        case cancelled
    }

    // MARK: - Claude (cloud)

    private func runClaude(
        _ request: InlineCompletionRequest,
        apiKey: String,
        config: Config,
        continuation: AsyncStream<InlineCompletionEvent>.Continuation
    ) async -> Outcome {
        guard !apiKey.isEmpty else { return .failed("Claude ghost text needs an API key (Settings → AI).") }
        let prompt = InlinePromptBuilder.claude(request)
        // Haiku 5.5: thinking off and low effort for latency; no
        // temperature (non-default sampling values are rejected).
        let body: [String: Any] = [
            "model":         Self.claudeModel,
            "max_tokens":    max(config.maxTokens, 64),
            "stream":        true,
            "thinking":      ["type": "disabled"],
            "output_config": ["effort": "low"],
            "system":        prompt.system,
            "messages":      [["role": "user", "content": prompt.user]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,               forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",         forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 15

        let promptTail = String(request.prefix.suffix(400))
        return await streamLines(req, body: body, label: "Claude", promptTail: promptTail,
                                 mode: request.mode, continuation: continuation) { line in
            guard line.hasPrefix("data:") else { return .skip }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let json = Self.json(payload) else { return .skip }
            switch json["type"] as? String {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String else { return .skip }
                return .append(text)
            case "message_stop":
                return .done
            case "error":
                let error = json["error"] as? [String: Any]
                return .error("Claude: \(error?["message"] as? String ?? "stream error")")
            default:
                return .skip
            }
        }
    }

    // MARK: - Next-edit prediction (Claude)

    enum NextEditResult: Sendable, Equatable {
        case candidate(NextEditCandidate)
        case none
        case failed(String)
        case rateLimited(until: Date, message: String)
    }

    /// One non-streaming Claude call — the answer is a small JSON object
    /// that's only usable once complete.
    func predictNextEdit(_ query: NextEditQuery, path: String, language: Language, apiKey: String) async -> NextEditResult {
        guard !apiKey.isEmpty else { return .failed("Next edit suggestions need a Claude API key (Settings → AI).") }
        let prompt = InlinePromptBuilder.nextEdit(query, path: path, language: language)
        let body: [String: Any] = [
            "model":         Self.claudeModel,
            "max_tokens":    512,
            "thinking":      ["type": "disabled"],
            "output_config": ["effort": "low"],
            "system":        prompt.system,
            "messages":      [["role": "user", "content": prompt.user]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,               forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",         forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let text = String(data: data, encoding: .utf8) ?? ""
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let message = "Claude error \(http.statusCode): \(Self.errorMessage(in: text))"
                if http.statusCode == 429 || http.statusCode == 529 {
                    let seconds = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 30
                    return .rateLimited(until: Date().addingTimeInterval(seconds), message: message)
                }
                return .failed(message)
            }
            guard let json = Self.json(text),
                  let content = json["content"] as? [[String: Any]],
                  let answer = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
            else { return .none }
            return InlinePromptBuilder.parseNextEdit(answer).map(NextEditResult.candidate) ?? .none
        } catch {
            if Task.isCancelled { return .none }
            if let urlError = error as? URLError, urlError.code == .cancelled { return .none }
            return .failed("Claude unreachable: \(error.localizedDescription)")
        }
    }

    // MARK: - Ollama (local)

    private func runOllama(
        _ request: InlineCompletionRequest,
        endpoint: String,
        model: String,
        config: Config,
        continuation: AsyncStream<InlineCompletionEvent>.Continuation
    ) async -> Outcome {
        let base = Self.trimSlash(endpoint)
        guard let url = URL(string: "\(base)/api/generate") else { return .failed("Invalid Ollama endpoint: \(endpoint)") }
        let caps = await ollamaCapabilities(endpoint: base, model: model)
        let pairKey = "\(base)|\(model)"

        var options: [String: Any] = [
            "temperature": request.variant > 0 ? max(config.temperature, 0.6) : config.temperature,
            "num_predict": config.maxTokens,
        ]
        var body: [String: Any] = ["model": model, "stream": true]
        if caps.thinking { body["think"] = false }
        let promptTail: String

        if let family = InlinePromptBuilder.FIMFamily.detect(model: model) {
            // Raw mode: Athena writes the model's own FIM tokens, which is
            // what lets several files sit in one prompt.
            body["raw"] = true
            body["prompt"] = InlinePromptBuilder.rawFIM(request, family: family, repoName: config.repoName)
            options["stop"] = family.stopTokens
            promptTail = String(request.prefix.suffix(400))
        } else {
            let generic = InlinePromptBuilder.commentedPrompt(request)
            body["prompt"] = generic.prompt
            if caps.insert, !generic.suffix.isEmpty, !suffixUnsupported.contains(pairKey) {
                body["suffix"] = generic.suffix
            }
            promptTail = String(generic.prompt.suffix(400))
        }
        body["options"] = options

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let parse: @Sendable (String) -> LineResult = { line in
            guard let json = Self.json(Substring(line)) else { return .skip }
            if let error = json["error"] as? String { return .error("Ollama (model \(model)): \(error)") }
            if let piece = json["response"] as? String, !piece.isEmpty { return .append(piece) }
            return (json["done"] as? Bool) == true ? .done : .skip
        }

        let outcome = await streamLines(req, body: body, label: "Ollama (model \(model))", promptTail: promptTail,
                                        mode: request.mode, continuation: continuation, parse: parse)
        // Some instruct templates refuse `suffix` despite advertising it;
        // remember and retry prompt-only once.
        if case .failed(let message) = outcome, body["suffix"] != nil,
           message.localizedCaseInsensitiveContains("suffix") || message.localizedCaseInsensitiveContains("insert") {
            suffixUnsupported.insert(pairKey)
            body["suffix"] = nil
            return await streamLines(req, body: body, label: "Ollama (model \(model))", promptTail: promptTail,
                                     mode: request.mode, continuation: continuation, parse: parse)
        }
        if case .failed(let message) = outcome, message.contains("unreachable") {
            return .failed("Ollama unreachable at \(base) — is `ollama serve` running?")
        }
        return outcome
    }

    /// Asks `POST /api/show` what the model supports, once per session.
    /// On failure assumes fill-in-middle works (the request will say
    /// otherwise) and that the model doesn't think.
    func ollamaCapabilities(endpoint: String, model: String) async -> OllamaCapabilities {
        let base = Self.trimSlash(endpoint)
        let key = "\(base)|\(model)"
        if let known = capabilities[key] { return known }
        guard let url = URL(string: "\(base)/api/show") else { return OllamaCapabilities(insert: true, thinking: false) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard
            let (data, response) = try? await URLSession.shared.data(for: req),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return OllamaCapabilities(insert: true, thinking: false) }

        let list = json["capabilities"] as? [String] ?? []
        let template = json["template"] as? String ?? ""
        let caps = OllamaCapabilities(
            insert: list.contains("insert") || template.contains(".Suffix"),
            thinking: list.contains("thinking")
        )
        capabilities[key] = caps
        return caps
    }

    /// Fetches installed model names from Ollama's `GET /api/tags`, for the
    /// Settings "Fetch models" picker. Empty on any failure.
    func fetchOllamaModels(endpoint: String) async -> [String] {
        let base = Self.trimSlash(endpoint)
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

    /// Tries llama.cpp's `/infill` first (real fill-in-middle with extra
    /// files); servers without it (LM Studio, vLLM…) fall back to the
    /// OpenAI `/completions` shape, prompt-only, remembered per endpoint.
    private func runOpenAICompatible(
        _ request: InlineCompletionRequest,
        endpoint: String,
        model: String,
        apiKey: String,
        config: Config,
        continuation: AsyncStream<InlineCompletionEvent>.Continuation
    ) async -> Outcome {
        let base = Self.trimSlash(endpoint)
        let temperature = request.variant > 0 ? max(config.temperature, 0.6) : config.temperature

        func authorized(_ url: URL) -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Only when set: servers without auth never expect the header.
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            req.timeoutInterval = 30
            return req
        }

        let sseText: @Sendable (String, String) -> LineResult = { line, field in
            guard line.hasPrefix("data:") else { return .skip }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return .done }
            guard let json = Self.json(payload) else { return .skip }
            if let error = json["error"] as? [String: Any] { return .error("Local model server: \(error["message"] as? String ?? "error")") }
            if field == "content" {
                if let piece = json["content"] as? String, !piece.isEmpty { return .append(piece) }
                return (json["stop"] as? Bool) == true ? .done : .skip
            }
            let choice = (json["choices"] as? [[String: Any]])?.first
            if let piece = choice?["text"] as? String, !piece.isEmpty { return .append(piece) }
            return .skip
        }

        if !infillUnsupported.contains(base), let url = URL(string: "\(Self.serverRoot(base))/infill") {
            let pieces = InlinePromptBuilder.infill(request)
            let body: [String: Any] = [
                "input_prefix": pieces.prefix,
                "input_suffix": pieces.suffix,
                "input_extra":  pieces.extra,
                "n_predict":    config.maxTokens,
                "temperature":  temperature,
                "stream":       true,
            ]
            let outcome = await streamLines(authorized(url), body: body, label: "Local model server (model \(model))",
                                            promptTail: String(pieces.prefix.suffix(400)), mode: request.mode,
                                            continuation: continuation) { sseText($0, "content") }
            switch outcome {
            case .failed(let message) where !message.contains("unreachable"):
                // An HTTP error: no /infill here. Fall through to /completions.
                infillUnsupported.insert(base)
            default:
                // Success, cancellation, or the server being down.
                return outcome
            }
        }

        guard let url = URL(string: "\(base)/completions") else { return .failed("Invalid endpoint: \(endpoint)") }
        let generic = InlinePromptBuilder.commentedPrompt(request)
        let body: [String: Any] = [
            "model":       model,
            "prompt":      generic.prompt,
            "max_tokens":  config.maxTokens,
            "temperature": temperature,
            "stream":      true,
        ]
        return await streamLines(authorized(url), body: body, label: "Local model server (model \(model))",
                                 promptTail: String(generic.prompt.suffix(400)), mode: request.mode,
                                 continuation: continuation) { sseText($0, "text") }
    }

    // MARK: - Shared streaming loop

    enum LineResult: Sendable {
        case append(String)
        case done
        case error(String)
        case skip
    }

    /// Sends `body` to `req`, feeds each response line to `parse`, and
    /// yields the cleaned cumulative text as it grows. Mid-line requests
    /// stop at the first line break — nothing past it can be used.
    private func streamLines(
        _ request: URLRequest,
        body: [String: Any],
        label: String,
        promptTail: String,
        mode: InlineCompletionMode,
        continuation: AsyncStream<InlineCompletionEvent>.Continuation,
        parse: @Sendable (String) -> LineResult
    ) async -> Outcome {
        var req = request
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed("\(label): bad request") }
        req.httpBody = data

        do {
            let (bytes, response) = try await Self.bytesWithConnectionRetry(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var detail = ""
                for try await line in bytes.lines {
                    detail += line
                    if detail.count > 400 { break }
                }
                let message = "\(label) error \(http.statusCode): \(Self.errorMessage(in: detail))"
                if http.statusCode == 429 || http.statusCode == 529 {
                    let seconds = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init) ?? 30
                    return .rateLimited(until: Date().addingTimeInterval(seconds), message: message)
                }
                return .failed(message)
            }

            var raw = ""
            var lastYielded: String?
            lineLoop: for try await line in bytes.lines {
                if Task.isCancelled { return .cancelled }
                switch parse(line) {
                case .append(let piece):
                    raw += piece
                    if let cleaned = InlinePromptBuilder.clean(raw, promptTail: promptTail, final: false),
                       cleaned != lastYielded {
                        lastYielded = cleaned
                        continuation.yield(.text(cleaned))
                        if mode == .midLine, cleaned.contains("\n") { break lineLoop }
                    }
                case .done:
                    break lineLoop
                case .error(let message):
                    return .failed(message)
                case .skip:
                    continue
                }
            }
            if Task.isCancelled { return .cancelled }
            return .finished(InlinePromptBuilder.clean(raw, promptTail: promptTail, final: true))
        } catch {
            // Every keystroke cancels the in-flight request; URLSession
            // surfaces that as URLError.cancelled — routine, not a failure.
            if Task.isCancelled { return .cancelled }
            if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
            return .failed("\(label) unreachable: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Performs `req` and retries on connection-level failures (host not yet
    /// listening, connection lost) that are typically transient — e.g. a
    /// local server still finishing startup.
    private static func bytesWithConnectionRetry(
        for req: URLRequest,
        attempts: Int = 3,
        initialDelay: Duration = .milliseconds(300)
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var delay = initialDelay
        for _ in 1..<attempts {
            do {
                return try await URLSession.shared.bytes(for: req)
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                // ContinuousClock, not Task.sleep(for:) — avoids a Swift 6.2
                // release-toolchain crash in swift_task_dealloc
                // (https://github.com/swiftlang/swift/issues/86204).
                let clock = ContinuousClock()
                try await clock.sleep(until: clock.now.advanced(by: delay))
                delay *= 2
            }
        }
        return try await URLSession.shared.bytes(for: req)
    }

    private func store(_ text: String, for key: Int) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = text
        if cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    /// Everything that changes the answer: model, alternative, mode, file,
    /// and the text right around the caret (edits far away don't).
    static func cacheKey(_ request: InlineCompletionRequest, backend: Backend) -> Int {
        var hasher = Hasher()
        hasher.combine(backend.cacheID)
        hasher.combine(request.variant)
        hasher.combine(request.mode.rawValue)
        hasher.combine(request.path)
        hasher.combine(String(request.prefix.suffix(1500)))
        hasher.combine(String(request.suffix.prefix(400)))
        return hasher.finalize()
    }

    private static func json(_ text: Substring) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func json(_ text: String) -> [String: Any]? { json(Substring(text)) }

    /// The `message` of a JSON error body, or the body itself, shortened.
    static func errorMessage(in body: String) -> String {
        if let json = json(body) {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["error"] as? String { return message }
        }
        return String(body.prefix(200))
    }

    private static func trimSlash(_ endpoint: String) -> String {
        endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
    }

    /// `http://host:8080/v1` → `http://host:8080` (llama.cpp serves
    /// `/infill` at the root, beside its OpenAI-compatible `/v1`).
    static func serverRoot(_ base: String) -> String {
        base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
    }
}
