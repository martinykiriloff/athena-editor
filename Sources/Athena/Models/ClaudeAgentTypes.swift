// ClaudeAgentTypes.swift
// Athena — domain types for the Claude Code agent session (stream-json protocol).
// Swift 6, strict concurrency.

import Foundation

// MARK: - JSONValue

/// A `Sendable`, `Equatable` JSON tree. Tool inputs and permission suggestions
/// arrive as free-form JSON that has to cross an actor boundary and then drive
/// SwiftUI diffing, so `[String: Any]` is not an option.
enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:            try c.encodeNil()
        case .bool(let v):     try c.encode(v)
        case .number(let v):   try c.encode(v)
        case .string(let v):   try c.encode(v)
        case .array(let v):    try c.encode(v)
        case .object(let v):   try c.encode(v)
        }
    }

    // MARK: Accessors

    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .number(let d) = self { return Int(d) }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Best-effort flattening for display — strings unwrap, everything else
    /// renders as compact JSON.
    var displayText: String {
        switch self {
        case .null:          return ""
        case .bool(let b):   return b ? "true" : "false"
        case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        case .string(let s): return s
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    /// Foundation representation, for handing back to `JSONSerialization`.
    var foundationObject: Any {
        switch self {
        case .null:          return NSNull()
        case .bool(let b):   return b
        case .number(let d): return d == d.rounded() && abs(d) < 9e15 ? Int(d) : d
        case .string(let s): return s
        case .array(let a):  return a.map(\.foundationObject)
        case .object(let o): return o.mapValues(\.foundationObject)
        }
    }

    /// Builds a value from `JSONSerialization` output.
    init(foundation object: Any) {
        switch object {
        case is NSNull:            self = .null
        case let n as NSNumber:
            // NSNumber erases Bool; CFBooleanGetTypeID distinguishes it.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else { self = .number(n.doubleValue) }
        case let s as String:      self = .string(s)
        case let a as [Any]:       self = .array(a.map(JSONValue.init(foundation:)))
        case let d as [String: Any]:
            self = .object(d.mapValues(JSONValue.init(foundation:)))
        default:                   self = .null
        }
    }
}

// MARK: - Permission mode

/// Mirrors the CLI's `--permission-mode`. `normal` is the CLI's `default`,
/// renamed because `default` is a Swift keyword.
enum ClaudePermissionMode: String, CaseIterable, Sendable, Identifiable, Codable {
    case normal
    case acceptEdits
    case plan
    case bypassPermissions

    var id: String { rawValue }

    /// The literal the CLI expects on `--permission-mode` and in the
    /// `set_permission_mode` control request.
    var cliValue: String {
        switch self {
        case .normal:            return "default"
        case .acceptEdits:       return "acceptEdits"
        case .plan:              return "plan"
        case .bypassPermissions: return "bypassPermissions"
        }
    }

    var title: String {
        switch self {
        case .normal:            return "Ask permission"
        case .acceptEdits:       return "Accept edits"
        case .plan:              return "Plan mode"
        case .bypassPermissions: return "Bypass permissions"
        }
    }

    var shortTitle: String {
        switch self {
        case .normal:            return "Ask"
        case .acceptEdits:       return "Auto-edit"
        case .plan:              return "Plan"
        case .bypassPermissions: return "Bypass"
        }
    }

    var icon: String {
        switch self {
        case .normal:            return "hand.raised"
        case .acceptEdits:       return "square.and.pencil"
        case .plan:              return "list.bullet.clipboard"
        case .bypassPermissions: return "bolt"
        }
    }

    /// `bypassPermissions` disables every guardrail — the panel warns on it.
    var isDangerous: Bool { self == .bypassPermissions }
}

// MARK: - Model

struct ClaudeModelOption: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let name: String
    /// Value passed to `--model` / `set_model`; `nil` keeps the CLI default.
    let alias: String?

    static let auto    = ClaudeModelOption(id: "auto",   name: "Default", alias: nil)
    static let opus    = ClaudeModelOption(id: "opus",   name: "Opus",    alias: "opus")
    static let sonnet  = ClaudeModelOption(id: "sonnet", name: "Sonnet",  alias: "sonnet")
    static let haiku   = ClaudeModelOption(id: "haiku",  name: "Haiku",   alias: "haiku")

    static let all: [ClaudeModelOption] = [.auto, .opus, .sonnet, .haiku]

    static func option(id: String) -> ClaudeModelOption {
        all.first { $0.id == id } ?? .auto
    }
}

// MARK: - Tool calls

enum ClaudeToolStatus: String, Sendable, Equatable, Codable {
    /// Input JSON is still streaming in.
    case pending
    /// A `can_use_tool` prompt is on screen for this call.
    case awaitingPermission
    /// Input complete, executing.
    case running
    case success
    case failed
    case denied

    var isTerminal: Bool {
        self == .success || self == .failed || self == .denied
    }
}

/// One `tool_use` block and the `tool_result` that answers it, joined by id.
struct ClaudeToolCall: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var input: JSONValue = .object([:])
    var status: ClaudeToolStatus = .pending
    var resultText: String = ""
    var isError: Bool = false
    /// Set when this call was made by a subagent rather than the main loop.
    var parentToolUseId: String?
    var startedAt: Date = Date()
    var finishedAt: Date?

    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

// MARK: - Tool presentation

/// How a tool call's body renders in the timeline.
enum ClaudeToolDetail: Sendable, Equatable {
    case none
    /// A shell command or code snippet shown monospaced.
    case code(String)
    /// A before/after edit, rendered as a unified diff.
    case diff(old: String, new: String)
    /// `TodoWrite`'s checklist.
    case todos([ClaudeTodoItem])
}

struct ClaudeTodoItem: Identifiable, Sendable, Equatable {
    let id = UUID()
    var content: String
    var status: String

    var isDone: Bool       { status == "completed" }
    var isInProgress: Bool { status == "in_progress" }
}

extension ClaudeToolCall {

    /// Path-like argument this call operates on, if any — drives the header
    /// text and the "open this file" affordance.
    var filePath: String? {
        input["file_path"]?.stringValue
            ?? input["path"]?.stringValue
            ?? input["notebook_path"]?.stringValue
    }

    /// SF Symbol matching the tool's effect, mirroring VS Code's tool glyphs.
    var icon: String {
        switch name {
        case "Read", "NotebookRead":        return "doc.text"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil.line"
        case "Write":                       return "square.and.pencil"
        case "Bash", "BashOutput":          return "terminal"
        case "KillShell", "KillBash":       return "stop.circle"
        case "Glob":                        return "folder.badge.questionmark"
        case "Grep":                        return "magnifyingglass"
        case "WebFetch":                    return "globe"
        case "WebSearch":                   return "safari"
        case "Task", "Agent":               return "person.2"
        case "TodoWrite":                   return "checklist"
        case "Skill":                       return "sparkles"
        case "LSP":                         return "chevron.left.forwardslash.chevron.right"
        default:
            return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// Short human label — "Read", "Bash", "Search", or the MCP tool's own name.
    var displayName: String {
        switch name {
        case "Grep":      return "Search"
        case "Glob":      return "Find files"
        case "WebFetch":  return "Fetch"
        case "WebSearch": return "Web search"
        case "TodoWrite": return "Update plan"
        default:
            guard name.hasPrefix("mcp__") else { return name }
            // mcp__server__tool → "tool (server)"
            let parts = name.dropFirst(5).components(separatedBy: "__")
            guard parts.count >= 2 else { return name }
            return "\(parts.dropFirst().joined(separator: "__")) (\(parts[0]))"
        }
    }

    /// One-line argument summary shown beside the tool name.
    var summary: String {
        switch name {
        case "Bash":
            return input["description"]?.stringValue
                ?? Self.firstLine(input["command"]?.stringValue ?? "")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead":
            return filePath.map(Self.shortPath) ?? ""
        case "Grep":
            let pattern = input["pattern"]?.stringValue ?? ""
            if let glob = input["glob"]?.stringValue, !glob.isEmpty { return "\(pattern) in \(glob)" }
            return pattern
        case "Glob":
            return input["pattern"]?.stringValue ?? ""
        case "WebFetch":
            return input["url"]?.stringValue ?? ""
        case "WebSearch":
            return input["query"]?.stringValue ?? ""
        case "Task", "Agent":
            return input["description"]?.stringValue ?? input["subagent_type"]?.stringValue ?? ""
        case "Skill":
            return input["skill"]?.stringValue ?? ""
        case "TodoWrite":
            return ""
        default:
            // MCP and unknown tools: show the first scalar argument.
            guard let obj = input.objectValue else { return "" }
            for key in obj.keys.sorted() {
                if let s = obj[key]?.stringValue, !s.isEmpty { return Self.firstLine(s) }
            }
            return ""
        }
    }

    /// The expandable body for this call.
    var detail: ClaudeToolDetail {
        switch name {
        case "Bash":
            return .code(input["command"]?.stringValue ?? "")
        case "Edit":
            return .diff(
                old: input["old_string"]?.stringValue ?? "",
                new: input["new_string"]?.stringValue ?? ""
            )
        case "Write":
            return .code(input["content"]?.stringValue ?? "")
        case "TodoWrite":
            let items = (input["todos"]?.arrayValue ?? []).compactMap { item -> ClaudeTodoItem? in
                guard let content = item["content"]?.stringValue else { return nil }
                return ClaudeTodoItem(content: content, status: item["status"]?.stringValue ?? "pending")
            }
            return .todos(items)
        case "MultiEdit":
            // Render the concatenation of every edit as one diff.
            let edits = input["edits"]?.arrayValue ?? []
            let old = edits.compactMap { $0["old_string"]?.stringValue }.joined(separator: "\n…\n")
            let new = edits.compactMap { $0["new_string"]?.stringValue }.joined(separator: "\n…\n")
            return .diff(old: old, new: new)
        case "Read", "Glob", "Grep", "WebSearch", "TodoRead":
            return .none
        default:
            guard let obj = input.objectValue, !obj.isEmpty else { return .none }
            let pretty = obj.keys.sorted()
                .map { "\($0): \(obj[$0]?.displayText ?? "")" }
                .joined(separator: "\n")
            return .code(pretty)
        }
    }

    /// True when the call changed files on disk — those get a diff affordance
    /// and a "review changes" accent in the timeline.
    var isMutating: Bool {
        ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(name)
    }

    // MARK: Formatting helpers

    static func shortPath(_ path: String) -> String {
        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        return parts.suffix(2).joined(separator: "/")
    }

    static func firstLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).first ?? text
    }
}

// MARK: - Permissions

/// A `can_use_tool` control request awaiting the user's answer.
struct ClaudePermissionRequest: Identifiable, Sendable, Equatable {
    /// The control protocol's `request_id` — the key the response must echo.
    let id: String
    let toolUseId: String?
    let toolName: String
    let displayName: String
    let input: JSONValue
    /// The CLI's explanation ("This command requires approval").
    let reason: String?
    /// Rule updates the CLI offers, powering "always allow" buttons.
    let suggestions: [ClaudePermissionSuggestion]

    /// A synthetic tool call so the prompt can reuse the tool row rendering.
    var previewCall: ClaudeToolCall {
        ClaudeToolCall(id: toolUseId ?? id, name: toolName, input: input, status: .awaitingPermission)
    }
}

struct ClaudePermissionSuggestion: Identifiable, Sendable, Equatable {
    /// Index within the request's suggestion list — stable and unique per request.
    let id: Int
    let label: String
    /// The raw suggestion object, echoed back verbatim in `updatedPermissions`.
    let raw: JSONValue
}

enum ClaudePermissionDecision: Sendable, Equatable {
    case allowOnce
    case allowAlways(suggestion: ClaudePermissionSuggestion)
    case deny(message: String?)
}

// MARK: - Session metadata

struct ClaudeMCPServerStatus: Identifiable, Sendable, Equatable {
    let name: String
    let status: String
    var id: String { name }

    var isConnected: Bool { status == "connected" }
}

/// The `system`/`init` payload — what the session can actually do.
struct ClaudeSessionInfo: Sendable, Equatable {
    var sessionId: String = ""
    var model: String = ""
    var cwd: String = ""
    var permissionMode: String = "default"
    var tools: [String] = []
    var mcpServers: [ClaudeMCPServerStatus] = []
    var slashCommandNames: [String] = []
    var agents: [String] = []
    var version: String = ""
}

/// A slash command discovered from the live session's `initialize` response —
/// this is the real command list for this machine (skills, plugins, project
/// commands), not a hard-coded one.
struct ClaudeSlashCommand: Identifiable, Sendable, Equatable {
    let name: String
    let description: String
    let argumentHint: String

    var id: String { name }
    var trigger: String { "/" + name }

    /// Plugin commands are namespaced `plugin:command`; group by that prefix.
    var group: String {
        guard let colon = name.firstIndex(of: ":") else { return "Built-in" }
        return String(name[name.startIndex..<colon])
    }
}

// MARK: - Turn result

/// The `result` message closing a turn — cost, tokens and timing.
struct ClaudeTurnResult: Sendable, Equatable {
    var isError: Bool = false
    var subtype: String = ""
    var text: String = ""
    var durationMs: Int = 0
    var costUSD: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var numTurns: Int = 0

    /// Everything the model had to read this turn.
    var totalInputTokens: Int { inputTokens + cacheReadTokens + cacheCreationTokens }
}

// MARK: - Context references

/// A workspace file (or a selected range within one) attached to a prompt —
/// Athena's equivalent of VS Code's `@file` chips and "share selection".
struct ClaudeContextRef: Identifiable, Sendable, Equatable, Hashable {
    enum Kind: String, Sendable, Equatable, Hashable {
        case file
        case selection
        case folder
    }

    let url: URL
    var lineRange: ClosedRange<Int>?
    var kind: Kind = .file

    var id: String {
        guard let lineRange else { return "\(kind.rawValue):\(url.path)" }
        return "\(kind.rawValue):\(url.path)#L\(lineRange.lowerBound)-\(lineRange.upperBound)"
    }

    var fileName: String { url.lastPathComponent }

    var label: String {
        guard let lineRange else { return fileName }
        return lineRange.lowerBound == lineRange.upperBound
            ? "\(fileName):\(lineRange.lowerBound)"
            : "\(fileName):\(lineRange.lowerBound)-\(lineRange.upperBound)"
    }

    /// Path relative to `root` when inside it, else the absolute path.
    func path(relativeTo root: URL?) -> String {
        guard let root else { return url.path }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return url.path }
        return String(url.path.dropFirst(rootPath.count))
    }

    /// The `@`-mention text the CLI resolves, matching Claude Code's own syntax.
    func promptFragment(relativeTo root: URL?) -> String {
        let p = path(relativeTo: root)
        guard let lineRange else { return "@\(p)" }
        return lineRange.lowerBound == lineRange.upperBound
            ? "@\(p)#L\(lineRange.lowerBound)"
            : "@\(p)#L\(lineRange.lowerBound)-\(lineRange.upperBound)"
    }
}

// MARK: - Timeline

enum ClaudeNoticeLevel: String, Sendable, Equatable {
    case info
    case warning
    case error
}

/// One row in the conversation. The panel renders a flat, ordered list of
/// these — user turns, assistant prose, thinking, tool calls, permission
/// prompts and turn summaries all interleaved exactly as they arrived.
struct ClaudeTimelineItem: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case user(text: String, attachments: [ClaudeAttachment], contexts: [ClaudeContextRef])
        case assistant(text: String, isStreaming: Bool)
        case thinking(text: String, isStreaming: Bool)
        case tool(ClaudeToolCall)
        case permission(ClaudePermissionRequest)
        case notice(text: String, level: ClaudeNoticeLevel)
        case summary(ClaudeTurnResult)
    }

    let id: String
    var kind: Kind
    /// Non-nil when the row came from a subagent's nested loop.
    var parentToolUseId: String?

    var isFromSubagent: Bool { parentToolUseId != nil }

    /// The tool call carried by a `.tool` row, for in-place mutation.
    var toolCall: ClaudeToolCall? {
        if case .tool(let call) = kind { return call }
        return nil
    }
}
