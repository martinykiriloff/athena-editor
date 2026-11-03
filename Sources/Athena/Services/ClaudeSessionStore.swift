// ClaudeSessionStore.swift
// Athena — lists resumable Claude Code conversations from the CLI's own store.
// Swift 6, strict concurrency.

import Foundation

// MARK: - ClaudeStoredSession

/// A past conversation the CLI can resume by id.
struct ClaudeStoredSession: Identifiable, Sendable, Equatable {
    let id: String
    let cwd: String
    /// First thing the user asked, used as the conversation's title.
    let title: String
    let modifiedAt: Date

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled conversation" }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }
}

// MARK: - ClaudeSessionStore

/// Reads the transcript files Claude Code writes under
/// `~/.claude/projects/<escaped-cwd>/<session-id>.jsonl`.
///
/// The CLI owns this format; Athena only reads it, and only enough of each
/// file to title the entry — so an unfamiliar or changed layout degrades to an
/// empty history list rather than an error.
actor ClaudeSessionStore {

    /// Lines scanned per transcript before giving up on finding a title —
    /// bounded so a huge conversation can't stall the picker.
    private static let maxScannedLines = 400

    /// The most recent conversations rooted at `workspace`, newest first.
    func recentSessions(
        workspace: URL,
        account: ClaudeAccount,
        limit: Int = 15
    ) -> [ClaudeStoredSession] {
        let projectsRoot = Self.configRoot(for: account).appending(path: "projects")
        let fm = FileManager.default

        guard let directories = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        // The CLI's directory naming is its own business, so prefer the
        // expected name but fall back to matching each transcript's recorded
        // `cwd` — which is authoritative either way.
        let expected = Self.escapedDirectoryName(for: workspace)
        let candidates = directories.filter { $0.lastPathComponent == expected }
        let searchRoots = candidates.isEmpty ? directories : candidates

        var sessions: [ClaudeStoredSession] = []
        for root in searchRoots {
            sessions += transcripts(in: root, matching: workspace.path)
        }

        return sessions
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Transcript history

    /// Most rows a reopened conversation shows; older ones are summarised in
    /// a notice so a months-long session can't make the panel sluggish.
    static let historyLimit = 600

    /// A past conversation's turns, rebuilt as timeline rows.
    struct History: Sendable, Equatable {
        var items: [ClaudeTimelineItem]
        /// Rows dropped from the start to stay within `historyLimit`.
        var omitted: Int
    }

    /// Reads the transcript for `sessionId` and rebuilds its timeline. In the
    /// streaming protocol Athena speaks, `--resume` restores the model's
    /// context but sends none of the earlier turns back, so the panel has to
    /// read them from the CLI's own transcript.
    func history(sessionId: String, workspace: URL?, account: ClaudeAccount) -> History {
        guard let url = transcriptURL(sessionId: sessionId, workspace: workspace, account: account),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return History(items: [], omitted: 0) }
        return Self.history(fromTranscript: data, workspaceRoot: workspace)
    }

    private func transcriptURL(sessionId: String, workspace: URL?, account: ClaudeAccount) -> URL? {
        let projects = Self.configRoot(for: account).appending(path: "projects")
        let fm = FileManager.default
        let fileName = "\(sessionId).jsonl"
        if let workspace {
            let expected = projects.appending(path: Self.escapedDirectoryName(for: workspace)).appending(path: fileName)
            if fm.fileExists(atPath: expected.path) { return expected }
        }
        let directories = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return directories
            .map { $0.appending(path: fileName) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// Rebuilds the visible conversation from transcript lines.
    ///
    /// Lines link to their predecessor by `parentUuid`. The conversation is
    /// the chain ending at the last message — which leaves out turns a
    /// rewind abandoned — plus the results of tool calls on that chain:
    /// parallel calls fork it, each result hanging off its own call.
    static func history(fromTranscript data: Data, workspaceRoot: URL?, limit: Int = historyLimit) -> History {
        struct Entry {
            let uuid: String
            let type: String
            let object: JSONValue
        }

        let decoder = JSONDecoder()
        var parentOf: [String: String] = [:]
        var messages: [Entry] = []

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // Only conversation and attachment lines take part in the chain;
            // the request blobs are most of the file and are skipped unread.
            guard Self.mayLink(line),
                  let object = try? decoder.decode(JSONValue.self, from: Data(line)),
                  let uuid = object["uuid"]?.stringValue,
                  let type = object["type"]?.stringValue
            else { continue }
            if let parent = object["parentUuid"]?.stringValue ?? object["logicalParentUuid"]?.stringValue {
                parentOf[uuid] = parent
            }
            guard type == "user" || type == "assistant",
                  object["isSidechain"]?.boolValue != true
            else { continue }
            messages.append(Entry(uuid: uuid, type: type, object: object))
        }
        guard let last = messages.last else { return History(items: [], omitted: 0) }

        var chain = Set<String>()
        var cursor: String? = last.uuid
        while let current = cursor, chain.insert(current).inserted {
            cursor = parentOf[current]
        }

        var callsOnChain = Set<String>()
        for entry in messages where entry.type == "assistant" && chain.contains(entry.uuid) {
            for block in entry.object["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                if let id = block["id"]?.stringValue { callsOnChain.insert(id) }
            }
        }

        var builder = HistoryBuilder(workspaceRoot: workspaceRoot)
        for entry in messages {
            let content = entry.object["message"]?["content"]
            let answersChain = entry.type == "user" && (content?.arrayValue ?? []).contains {
                $0["type"]?.stringValue == "tool_result" && callsOnChain.contains($0["tool_use_id"]?.stringValue ?? "")
            }
            guard chain.contains(entry.uuid) || answersChain else { continue }
            builder.add(entry.object, uuid: entry.uuid)
        }

        var items = builder.finish()
        let omitted = max(0, items.count - limit)
        if omitted > 0 { items.removeFirst(omitted) }
        return History(items: items, omitted: omitted)
    }

    /// Cheap byte check before decoding: does the line declare one of the
    /// types that carry `uuid`/`parentUuid`?
    private static func mayLink(_ line: Data.SubSequence) -> Bool {
        for marker in linkMarkers where line.range(of: marker) != nil { return true }
        return false
    }

    private static let linkMarkers: [Data] = [
        #""type":"user""#, #""type":"assistant""#, #""type":"attachment""#, #""type":"system""#,
        #""type": "user""#, #""type": "assistant""#,
    ].map { Data($0.utf8) }

    // MARK: Private

    private func transcripts(in directory: URL, matching cwd: String) -> [ClaudeStoredSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Newest first, so the scan cost is bounded by `limit` in practice.
        let transcripts = files
            .filter { $0.pathExtension == "jsonl" }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(40)

        return transcripts.compactMap { url, date in
            guard let summary = Self.summarize(transcript: url), summary.cwd == cwd else { return nil }
            return ClaudeStoredSession(
                id: url.deletingPathExtension().lastPathComponent,
                cwd: summary.cwd,
                title: summary.title,
                modifiedAt: date
            )
        }
    }

    /// Pulls the working directory and the opening user prompt out of a
    /// transcript without loading the whole file.
    private static func summarize(transcript url: URL) -> (cwd: String, title: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // 256 KB comfortably covers the header plus the first few turns.
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var cwd: String?
        var title: String?

        for line in text.components(separatedBy: .newlines).prefix(maxScannedLines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if cwd == nil, let value = object["cwd"] as? String { cwd = value }
            if title == nil, let text = firstUserText(in: object) { title = text }
            if cwd != nil && title != nil { break }
        }

        guard let cwd else { return nil }
        return (cwd, title ?? "")
    }

    /// The text of a user turn, skipping the tool results and meta entries
    /// that share the same `user` type in the transcript.
    private static func firstUserText(in object: [String: Any]) -> String? {
        guard object["type"] as? String == "user",
              object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return nil }

        // A slash command (`/clear`) makes a poor title; the conversation
        // view shows it, the history menu skips it.
        func title(_ raw: String) -> String? {
            raw.contains("<command-name>") ? nil : visibleUserText(raw)
        }
        if let text = message["content"] as? String {
            return title(text)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            guard let text = (block["text"] as? String).flatMap(title) else { continue }
            return text
        }
        return nil
    }

    // MARK: Injected text

    /// Wrappers the client or CLI adds around a turn that the user didn't
    /// type: reminders, browser/tool instructions, hook output, and the
    /// output of local commands.
    private static let hiddenTags = [
        "system-reminder", "browser_instruction", "user-prompt-submit-hook",
        "local-command-stdout", "local-command-stderr", "local-command-caveat",
        "bash-stdout", "bash-stderr", "command-message", "ide_selection", "ide_opened_file",
        // Results of background agents, fed back into the conversation.
        "task-notification",
    ]

    /// What the user actually wrote in a transcript text block, or `nil`
    /// when nothing is left: injected wrappers are removed (they can share
    /// a block with the typed text), pasted content is unwrapped and kept,
    /// and a slash command reads as `/name args`.
    static func visibleUserText(_ raw: String) -> String? {
        var text = raw
        for tag in hiddenTags {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)[^>]*>",
                with: "", options: .regularExpression
            )
        }
        // `<command-name>/model</command-name>…<command-args>opus</command-args>`
        if let name = firstMatch(in: text, tag: "command-name") {
            let args = firstMatch(in: text, tag: "command-args") ?? ""
            text = args.isEmpty ? name : "\(name) \(args)"
        }
        if let command = firstMatch(in: text, tag: "bash-input") {
            text = "! \(command)"
        }
        // Pasted content is the user's own; keep it, minus the wrapper.
        text = text.replacingOccurrences(of: "</?pasted_content\\b[^>]*>", with: "", options: .regularExpression)
        // Removed wrappers leave gaps; one blank line is enough.
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstMatch(in text: String, tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)\\b[^>]*>", options: .regularExpression),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `~/.claude`, or the account's own config root.
    static func configRoot(for account: ClaudeAccount) -> URL {
        if let dir = account.configDirectory {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude")
    }

    /// The CLI's project-directory name for a working directory: every path
    /// separator and dot becomes a dash.
    static func escapedDirectoryName(for url: URL) -> String {
        url.path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }
}

// MARK: - HistoryBuilder

/// Turns transcript messages into the same rows a live session produces:
/// prose, thinking, tool calls joined to their results, and user turns with
/// Athena's own `@` mentions and attachment list turned back into chips.
private struct HistoryBuilder {
    let workspaceRoot: URL?
    private(set) var items: [ClaudeTimelineItem] = []
    private var toolRows: [String: Int] = [:]

    init(workspaceRoot: URL?) {
        self.workspaceRoot = workspaceRoot
    }

    mutating func add(_ object: JSONValue, uuid: String) {
        let date = object["timestamp"]?.stringValue.flatMap(Self.parseDate)
        guard let content = object["message"]?["content"] else { return }

        if object["type"]?.stringValue == "assistant" {
            for (index, block) in (content.arrayValue ?? []).enumerated() {
                addAssistantBlock(block, id: "history:\(uuid)#\(index)", date: date)
            }
            return
        }

        // User line: typed text, or the results of earlier tool calls.
        guard object["isMeta"]?.boolValue != true else { return }
        if let text = content.stringValue {
            addUserText(text, images: 0, id: "history:\(uuid)")
            return
        }
        var texts: [String] = []
        var images = 0
        for block in content.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue { texts.append(text) }
            case "image":
                images += 1
            case "tool_result":
                let denied = object["toolDenialKind"]?.stringValue != nil
                addToolResult(block, date: date, denied: denied)
            default:
                continue
            }
        }
        if !texts.isEmpty || images > 0 {
            addUserText(texts.joined(separator: "\n\n"), images: images, id: "history:\(uuid)")
        }
    }

    /// Closes out calls whose result never arrived (the session ended
    /// mid-call), so they don't spin forever in a finished conversation.
    func finish() -> [ClaudeTimelineItem] {
        var result = items
        for index in toolRows.values {
            guard case .tool(var call) = result[index].kind, !call.status.isTerminal else { continue }
            call.status = .failed
            if call.resultText.isEmpty { call.resultText = "No result recorded — the session ended before this call finished." }
            result[index].kind = .tool(call)
        }
        return result
    }

    // MARK: Blocks

    private mutating func addAssistantBlock(_ block: JSONValue, id: String, date: Date?) {
        switch block["type"]?.stringValue {
        case "text":
            let text = block["text"]?.stringValue ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            items.append(.init(id: id, kind: .assistant(text: text, isStreaming: false)))
        case "thinking":
            // Thinking text is often omitted from transcripts; skip empty rows.
            let text = block["thinking"]?.stringValue ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            items.append(.init(id: id, kind: .thinking(text: text, isStreaming: false)))
        case "tool_use":
            guard let callId = block["id"]?.stringValue, toolRows[callId] == nil else { return }
            var call = ClaudeToolCall(id: callId, name: block["name"]?.stringValue ?? "Tool")
            call.input = block["input"] ?? .object([:])
            call.status = .running
            if let date { call.startedAt = date }
            toolRows[callId] = items.count
            items.append(.init(id: "tool:\(callId)", kind: .tool(call)))
        default:
            return
        }
    }

    private mutating func addToolResult(_ block: JSONValue, date: Date?, denied: Bool) {
        guard let callId = block["tool_use_id"]?.stringValue,
              let index = toolRows[callId],
              case .tool(var call) = items[index].kind
        else { return }
        let isError = block["is_error"]?.boolValue ?? false
        call.resultText = ClaudeStreamDecoder.toolResultText(block["content"])
        call.isError = isError
        call.status = denied ? .denied : (isError ? .failed : .success)
        call.finishedAt = date ?? call.startedAt
        items[index].kind = .tool(call)
    }

    private mutating func addUserText(_ raw: String, images: Int, id: String) {
        // Injected wrappers (<system-reminder>, <browser_instruction>, …)
        // aren't something the user typed.
        let text = ClaudeSessionStore.visibleUserText(raw) ?? ""
        if text.isEmpty, images == 0 { return }
        if text.hasPrefix("[Request interrupted by user") {
            items.append(.init(id: id, kind: .notice(text: "Interrupted.", level: .info)))
            return
        }
        var parsed = Self.parseAthenaPrompt(text, workspaceRoot: workspaceRoot)
        if images > 0 {
            let note = images == 1 ? "[image]" : "[\(images) images]"
            parsed.text = parsed.text.isEmpty ? note : parsed.text + "\n\n" + note
        }
        guard !parsed.text.isEmpty || !parsed.attachments.isEmpty || !parsed.contexts.isEmpty else { return }
        items.append(.init(id: id, kind: .user(text: parsed.text, attachments: parsed.attachments, contexts: parsed.contexts)))
    }

    // MARK: Helpers

    /// Undoes `AppState.claudePromptPayload`: a leading paragraph of `@`
    /// mentions becomes context chips and a trailing "Attached files:" list
    /// becomes attachments, leaving the prose the user actually typed.
    static func parseAthenaPrompt(_ text: String, workspaceRoot: URL?) -> (text: String, attachments: [ClaudeAttachment], contexts: [ClaudeContextRef]) {
        var paragraphs = text.components(separatedBy: "\n\n")
        var contexts: [ClaudeContextRef] = []
        var attachments: [ClaudeAttachment] = []

        if let first = paragraphs.first {
            let tokens = first.split(separator: " ").map(String.init)
            if !tokens.isEmpty, tokens.allSatisfy({ $0.hasPrefix("@") && $0.count > 1 }) {
                contexts = tokens.compactMap { contextRef(from: $0, workspaceRoot: workspaceRoot) }
                if contexts.count == tokens.count { paragraphs.removeFirst() } else { contexts = [] }
            }
        }
        if let start = paragraphs.firstIndex(where: { $0.hasPrefix("Attached files:\n") }) {
            let lines = paragraphs[start].components(separatedBy: "\n").dropFirst()
            let paths = lines.compactMap { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : nil }
            if paths.count == lines.count {
                attachments = paths.map { ClaudeAttachment(url: URL(fileURLWithPath: $0)) }
                // The ffmpeg hint for videos follows the list; it's Athena's, too.
                paragraphs.removeSubrange(start...)
            }
        }
        return (paragraphs.joined(separator: "\n\n"), attachments, contexts)
    }

    /// `@src/app.ts#L3-9` → a context chip for that file and range.
    static func contextRef(from token: String, workspaceRoot: URL?) -> ClaudeContextRef? {
        var spec = String(token.dropFirst())
        var range: ClosedRange<Int>?
        if let hash = spec.range(of: "#L") {
            let lines = spec[hash.upperBound...].split(separator: "-").compactMap { Int($0) }
            spec = String(spec[..<hash.lowerBound])
            if let lower = lines.first { range = lower...max(lower, lines.last ?? lower) }
        }
        guard !spec.isEmpty else { return nil }
        let url = spec.hasPrefix("/") || workspaceRoot == nil
            ? URL(fileURLWithPath: spec)
            : workspaceRoot!.appending(path: spec)
        return ClaudeContextRef(url: url, lineRange: range, kind: range == nil ? .file : .selection)
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
