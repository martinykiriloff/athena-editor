// ClaudeService.swift
// Athena — streams responses from the Anthropic Messages API (SSE).
// Swift 6, strict concurrency.

import Foundation

// MARK: - Request / Response Codable types

private struct AnthropicMessage: Codable {
    var role: String
    var content: String
}

private struct AnthropicRequest: Codable {
    var model: String = "claude-sonnet-4-6"
    var max_tokens: Int = 8096
    var stream: Bool = true
    var system: String?
    var messages: [AnthropicMessage]
}

private struct StreamDelta: Codable {
    var type: String?
    var text: String?
}

private struct StreamEvent: Codable {
    var type: String
    var delta: StreamDelta?
}

// MARK: - ClaudeService

actor ClaudeService {

    // MARK: State

    private var currentTask: Task<Void, Never>?

    // MARK: Public API

    /// Streams token chunks from the Anthropic API for the given prompt.
    /// The returned stream yields successive text deltas and finishes when the
    /// response is complete or the task is cancelled / `abort()` is called.
    func send(
        _ prompt: String,
        apiKey: String,
        systemPrompt: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    // Build request
                    let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    let body = AnthropicRequest(
                        system: systemPrompt,
                        messages: [AnthropicMessage(role: "user", content: prompt)]
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    // Stream bytes
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst("data: ".count))
                        if jsonStr == "[DONE]" { break }

                        guard
                            let data = jsonStr.data(using: .utf8),
                            let event = try? JSONDecoder().decode(StreamEvent.self, from: data)
                        else { continue }

                        if event.type == "content_block_delta",
                           let delta = event.delta,
                           delta.type == "text_delta",
                           let text = delta.text
                        {
                            continuation.yield(text)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Task<Void,Never> is Sendable; capture directly in the termination handler.
            let t = task
            continuation.onTermination = { _ in t.cancel() }

            // Store on the actor — safe because we're inside the actor's
            // AsyncThrowingStream initialiser closure which runs synchronously
            // before the first await in the Task body.
            Task { self.storeCurrentTask(task) }
        }
    }

    /// Cancels the in-flight streaming request, if any.
    func abort() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Quick heuristic check — does not validate the key against the API.
    func isKeyValid(_ key: String) -> Bool {
        key.hasPrefix("sk-ant-")
    }

    // MARK: Private helpers

    private func storeCurrentTask(_ task: Task<Void, Never>) {
        currentTask = task
    }
}
