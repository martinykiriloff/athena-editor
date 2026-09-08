// ClaudeStreamDecoder.swift
// Athena — turns the `claude` CLI's stream-json NDJSON lines into typed events.
// Swift 6, strict concurrency.

import Foundation

// MARK: - Events

/// One observable change produced by the agent's output stream.
///
/// Text events carry the *full* text for a block rather than a delta, keyed by
/// a stable `blockId`. Both incremental `stream_event` deltas and the CLI's
/// whole-block `assistant` snapshots therefore converge on the same value with
/// no risk of double-appending when both arrive for the same block.
enum ClaudeAgentEvent: Sendable, Equatable {
    case sessionInit(ClaudeSessionInfo)
    case textUpdated(blockId: String, text: String, parentToolUseId: String?)
    case thinkingUpdated(blockId: String, text: String, parentToolUseId: String?)
    case blockFinished(blockId: String)
    case toolStarted(id: String, name: String, parentToolUseId: String?)
    case toolInputUpdated(id: String, input: JSONValue)
    case toolResult(id: String, text: String, isError: Bool)
    case permissionRequest(ClaudePermissionRequest)
    case permissionDenied(toolUseId: String, reason: String)
    case status(String)
    case turnResult(ClaudeTurnResult)
    case notice(text: String, level: ClaudeNoticeLevel)
    /// The CLI answered a control request we sent (e.g. `initialize`).
    case controlResponse(requestId: String, payload: JSONValue)
}

// MARK: - ClaudeStreamDecoder

/// Pure, value-typed NDJSON → `ClaudeAgentEvent` translator.
///
/// Kept free of any process or actor concerns so the wire protocol can be
/// tested directly against captured CLI transcripts.
struct ClaudeStreamDecoder: Sendable {

    // MARK: State

    /// Accumulated partial `input_json_delta` text, keyed by tool_use id.
    private var partialToolInput: [String: String] = [:]
    /// Maps a streaming content-block index to the tool_use id opened at it.
    private var toolIdByBlockIndex: [Int: String] = [:]
    /// Accumulated text per streaming block id.
    private var textByBlockId: [String: String] = [:]
    /// The assistant message currently streaming, for block id derivation.
    private var currentMessageId: String = "msg"
    /// Whether this session has produced `stream_event` frames at all. When it
    /// has, whole-block `assistant` snapshots are used only to finalise tool
    /// inputs — their text is already covered by the partial stream.
    private var sawStreamEvents = false

    init() {}

    // MARK: Decoding

    /// Decodes one NDJSON line. Unknown or irrelevant frames yield `[]`.
    mutating func decode(line: String) -> [ClaudeAgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{") else { return [] }
        guard
            let data = trimmed.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let dict = raw as? [String: Any]
        else { return [] }

        let message = JSONValue(foundation: dict)

        switch message["type"]?.stringValue {
        case "system":       return decodeSystem(message)
        case "stream_event": return decodeStreamEvent(message)
        case "assistant":    return decodeAssistantSnapshot(message)
        case "user":         return decodeUserMessage(message)
        case "control_request":  return decodeControlRequest(message)
        case "control_response": return decodeControlResponse(message)
        case "result":       return [.turnResult(Self.turnResult(from: message))]
        default:             return []
        }
    }

    // MARK: system

    private func decodeSystem(_ message: JSONValue) -> [ClaudeAgentEvent] {
        switch message["subtype"]?.stringValue {
        case "init":
            return [.sessionInit(Self.sessionInfo(from: message))]

        case "status":
            guard let status = message["status"]?.stringValue else { return [] }
            return [.status(status)]

        case "permission_denied":
            let toolUseId = message["tool_use_id"]?.stringValue ?? ""
            let reason = message["message"]?.stringValue
                ?? message["decision_reason"]?.stringValue
                ?? "Permission denied"
            return [.permissionDenied(toolUseId: toolUseId, reason: reason)]

        case "notification":
            guard let text = message["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.notice(text: text, level: .info)]

        case "error":
            let text = message["message"]?.stringValue ?? "The agent reported an error."
            return [.notice(text: text, level: .error)]

        default:
            // hook_started / hook_response / compact_boundary and friends are
            // lifecycle noise the panel does not surface.
            return []
        }
    }

    // MARK: stream_event (partial messages)

    private mutating func decodeStreamEvent(_ message: JSONValue) -> [ClaudeAgentEvent] {
        sawStreamEvents = true
        guard let event = message["event"] else { return [] }
        let parent = message["parent_tool_use_id"]?.stringValue

        switch event["type"]?.stringValue {

        case "message_start":
            currentMessageId = event["message"]?["id"]?.stringValue ?? UUID().uuidString
            toolIdByBlockIndex.removeAll()
            return []

        case "content_block_start":
            guard let index = event["index"]?.intValue,
                  let block = event["content_block"] else { return [] }
            switch block["type"]?.stringValue {
            case "tool_use":
                guard let id = block["id"]?.stringValue else { return [] }
                let name = block["name"]?.stringValue ?? "Tool"
                toolIdByBlockIndex[index] = id
                partialToolInput[id] = ""
                return [.toolStarted(id: id, name: name, parentToolUseId: parent)]
            case "text":
                let blockId = blockId(for: index)
                textByBlockId[blockId] = block["text"]?.stringValue ?? ""
                return [.textUpdated(blockId: blockId, text: textByBlockId[blockId] ?? "", parentToolUseId: parent)]
            case "thinking":
                let blockId = blockId(for: index)
                textByBlockId[blockId] = block["thinking"]?.stringValue ?? ""
                return [.thinkingUpdated(blockId: blockId, text: textByBlockId[blockId] ?? "", parentToolUseId: parent)]
            default:
                return []
            }

        case "content_block_delta":
            guard let index = event["index"]?.intValue,
                  let delta = event["delta"] else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let chunk = delta["text"]?.stringValue else { return [] }
                let blockId = blockId(for: index)
                let text = (textByBlockId[blockId] ?? "") + chunk
                textByBlockId[blockId] = text
                return [.textUpdated(blockId: blockId, text: text, parentToolUseId: parent)]

            case "thinking_delta":
                guard let chunk = delta["thinking"]?.stringValue else { return [] }
                let blockId = blockId(for: index)
                let text = (textByBlockId[blockId] ?? "") + chunk
                textByBlockId[blockId] = text
                return [.thinkingUpdated(blockId: blockId, text: text, parentToolUseId: parent)]

            case "input_json_delta":
                guard let id = toolIdByBlockIndex[index],
                      let chunk = delta["partial_json"]?.stringValue else { return [] }
                let json = (partialToolInput[id] ?? "") + chunk
                partialToolInput[id] = json
                // Surface the input as soon as it parses so long tool inputs
                // (a big Write, say) render progressively instead of blank.
                guard let value = Self.parseJSONObject(json) else { return [] }
                return [.toolInputUpdated(id: id, input: value)]

            default:
                return []
            }

        case "content_block_stop":
            guard let index = event["index"]?.intValue else { return [] }
            if let id = toolIdByBlockIndex[index] {
                let json = partialToolInput[id] ?? ""
                partialToolInput[id] = nil
                guard let value = Self.parseJSONObject(json) else { return [] }
                return [.toolInputUpdated(id: id, input: value)]
            }
            return [.blockFinished(blockId: blockId(for: index))]

        default:
            return []
        }
    }

    private func blockId(for index: Int) -> String { "\(currentMessageId)#\(index)" }

    // MARK: assistant snapshots

    /// The CLI emits one `assistant` frame per completed content block. Tool
    /// inputs here are authoritative, so they always win; text is adopted only
    /// when partial streaming is unavailable (`--include-partial-messages` off
    /// or unsupported), which keeps the panel correct either way.
    private mutating func decodeAssistantSnapshot(_ message: JSONValue) -> [ClaudeAgentEvent] {
        guard let content = message["message"]?["content"]?.arrayValue else { return [] }
        let parent = message["parent_tool_use_id"]?.stringValue
        let uuid = message["uuid"]?.stringValue ?? UUID().uuidString
        var events: [ClaudeAgentEvent] = []

        for (index, block) in content.enumerated() {
            switch block["type"]?.stringValue {
            case "tool_use":
                guard let id = block["id"]?.stringValue else { continue }
                let name = block["name"]?.stringValue ?? "Tool"
                if partialToolInput[id] == nil && !sawStreamEvents {
                    events.append(.toolStarted(id: id, name: name, parentToolUseId: parent))
                }
                events.append(.toolInputUpdated(id: id, input: block["input"] ?? .object([:])))

            case "text" where !sawStreamEvents:
                let text = block["text"]?.stringValue ?? ""
                events.append(.textUpdated(blockId: "\(uuid)#\(index)", text: text, parentToolUseId: parent))

            case "thinking" where !sawStreamEvents:
                let text = block["thinking"]?.stringValue ?? ""
                events.append(.thinkingUpdated(blockId: "\(uuid)#\(index)", text: text, parentToolUseId: parent))

            default:
                continue
            }
        }
        return events
    }

    // MARK: user messages (tool results)

    private func decodeUserMessage(_ message: JSONValue) -> [ClaudeAgentEvent] {
        guard let content = message["message"]?["content"]?.arrayValue else { return [] }
        return content.compactMap { block in
            guard block["type"]?.stringValue == "tool_result",
                  let id = block["tool_use_id"]?.stringValue else { return nil }
            let isError = block["is_error"]?.boolValue ?? false
            return .toolResult(id: id, text: Self.toolResultText(block["content"]), isError: isError)
        }
    }

    /// `tool_result.content` is either a plain string or a content-block array.
    private static func toolResultText(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue { return text }
        guard let blocks = content.arrayValue else { return content.displayText }
        return blocks.compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text":  return block["text"]?.stringValue
            case "image": return "[image]"
            default:      return nil
            }
        }.joined(separator: "\n")
    }

    // MARK: control protocol

    private func decodeControlRequest(_ message: JSONValue) -> [ClaudeAgentEvent] {
        guard let requestId = message["request_id"]?.stringValue,
              let request = message["request"],
              request["subtype"]?.stringValue == "can_use_tool"
        else { return [] }

        let toolName = request["tool_name"]?.stringValue ?? "Tool"
        let suggestions = (request["permission_suggestions"]?.arrayValue ?? [])
            .enumerated()
            .map { index, raw in
                ClaudePermissionSuggestion(
                    id: index,
                    label: Self.suggestionLabel(raw, toolName: toolName),
                    raw: raw
                )
            }

        return [.permissionRequest(ClaudePermissionRequest(
            id: requestId,
            toolUseId: request["tool_use_id"]?.stringValue,
            toolName: toolName,
            displayName: request["display_name"]?.stringValue ?? toolName,
            input: request["input"] ?? .object([:]),
            reason: request["decision_reason"]?.stringValue,
            suggestions: suggestions
        ))]
    }

    private func decodeControlResponse(_ message: JSONValue) -> [ClaudeAgentEvent] {
        guard let response = message["response"],
              let requestId = response["request_id"]?.stringValue else { return [] }
        return [.controlResponse(requestId: requestId, payload: response["response"] ?? .object([:]))]
    }

    /// Turns an `addRules` suggestion into an "Always allow …" button label.
    static func suggestionLabel(_ suggestion: JSONValue, toolName: String) -> String {
        let behavior = suggestion["behavior"]?.stringValue ?? "allow"
        let verb = behavior == "deny" ? "Always deny" : "Always allow"

        if let rules = suggestion["rules"]?.arrayValue, let first = rules.first {
            let tool = first["toolName"]?.stringValue ?? toolName
            if let content = first["ruleContent"]?.stringValue, !content.isEmpty {
                return "\(verb) \(tool)(\(content))"
            }
            return "\(verb) \(tool)"
        }
        if suggestion["type"]?.stringValue == "addDirectories",
           let dirs = suggestion["directories"]?.arrayValue,
           let first = dirs.first?.stringValue {
            return "Always allow access to \(ClaudeToolCall.shortPath(first))"
        }
        if suggestion["mode"]?.stringValue != nil {
            return "Switch to \(suggestion["mode"]?.stringValue ?? "") mode"
        }
        return "\(verb) \(toolName)"
    }

    // MARK: Payload mapping

    static func sessionInfo(from message: JSONValue) -> ClaudeSessionInfo {
        var info = ClaudeSessionInfo()
        info.sessionId      = message["session_id"]?.stringValue ?? ""
        info.model          = message["model"]?.stringValue ?? ""
        info.cwd            = message["cwd"]?.stringValue ?? ""
        info.permissionMode = message["permissionMode"]?.stringValue ?? "default"
        info.version        = message["claude_code_version"]?.stringValue ?? ""
        info.tools          = (message["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
        info.agents         = (message["agents"]?.arrayValue ?? []).compactMap(\.stringValue)
        info.slashCommandNames = (message["slash_commands"]?.arrayValue ?? []).compactMap(\.stringValue)
        info.mcpServers = (message["mcp_servers"]?.arrayValue ?? []).compactMap { server in
            guard let name = server["name"]?.stringValue else { return nil }
            return ClaudeMCPServerStatus(name: name, status: server["status"]?.stringValue ?? "unknown")
        }
        return info
    }

    static func turnResult(from message: JSONValue) -> ClaudeTurnResult {
        var result = ClaudeTurnResult()
        result.isError    = message["is_error"]?.boolValue ?? false
        result.subtype    = message["subtype"]?.stringValue ?? ""
        result.text       = message["result"]?.stringValue ?? ""
        result.durationMs = message["duration_ms"]?.intValue ?? 0
        result.costUSD    = message["total_cost_usd"]?.doubleValue ?? 0
        result.numTurns   = message["num_turns"]?.intValue ?? 0

        if let usage = message["usage"] {
            result.inputTokens         = usage["input_tokens"]?.intValue ?? 0
            result.outputTokens        = usage["output_tokens"]?.intValue ?? 0
            result.cacheReadTokens     = usage["cache_read_input_tokens"]?.intValue ?? 0
            result.cacheCreationTokens = usage["cache_creation_input_tokens"]?.intValue ?? 0
        }
        return result
    }

    /// Parses accumulated `input_json_delta` text, tolerating a partial tail.
    static func parseJSONObject(_ json: String) -> JSONValue? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object([:]) }
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return JSONValue(foundation: object)
    }
}

// MARK: - Slash command parsing

extension ClaudeStreamDecoder {

    /// Extracts the command catalogue from an `initialize` control response.
    /// This is the machine's real command list — user skills, plugin commands
    /// and project commands included — so the palette never goes stale.
    static func slashCommands(fromInitializePayload payload: JSONValue) -> [ClaudeSlashCommand] {
        (payload["commands"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return ClaudeSlashCommand(
                name: name,
                description: entry["description"]?.stringValue ?? "",
                argumentHint: entry["argumentHint"]?.stringValue ?? ""
            )
        }
    }
}
