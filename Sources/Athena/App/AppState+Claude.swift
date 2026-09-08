// AppState+Claude.swift
// Athena — drives the Claude agent session and assembles its timeline.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    // MARK: - Session lifecycle

    /// True once a session process is up and its `init` frame has arrived.
    var claudeSessionIsLive: Bool { claudeSessionInfo != nil }

    /// Starts (or restarts) the agent process. Safe to call repeatedly — an
    /// existing session is torn down first.
    ///
    /// - Parameter resuming: a prior CLI session id to continue instead of
    ///   starting a fresh conversation.
    func startClaudeSession(resuming sessionId: String? = nil) {
        claudeEventTask?.cancel()
        claudeEventTask = nil

        let config = ClaudeAgentConfig(
            account: activeClaudeAccount,
            workingDirectory: workspace?.rootURL ?? FileManager.default.homeDirectoryForCurrentUser,
            additionalDirectories: [],
            model: claudeModel,
            permissionMode: claudePermissionMode,
            resumeSessionId: sessionId
        )

        claudeSessionGeneration += 1
        let generation = claudeSessionGeneration

        claudeStatus = "Starting…"
        claudeEventTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.claudeAgentService.start(config: config)
                for await event in stream {
                    // A newer session already owns the panel's state.
                    guard generation == self.claudeSessionGeneration else { return }
                    self.apply(event)
                }
            } catch {
                guard generation == self.claudeSessionGeneration else { return }
                self.appendClaudeNotice(Self.claudeLaunchFailureText(error), level: .error)
            }

            // The process exited. Clearing the task handle is what lets the
            // next message relaunch the agent instead of writing into a pipe
            // that is no longer there.
            guard generation == self.claudeSessionGeneration else { return }
            self.claudeEventTask = nil
            self.claudeIsStreaming = false
            self.claudeStatus = ""
            self.claudeSessionInfo = nil
        }
    }

    /// Clears the conversation and starts a fresh agent for it.
    ///
    /// The teardown deliberately does not stop the service itself: `start`
    /// stops the previous process as its own first step, and issuing a
    /// separate stop from here would race it — two unordered detached tasks,
    /// with a stop landing after the start and killing the new session.
    func newClaudeConversation(resuming sessionId: String? = nil) {
        clearClaudeConversation()
        startClaudeSession(resuming: sessionId)
    }

    /// Tears the session down and clears everything the panel shows.
    func resetClaudeSession() {
        clearClaudeConversation()
        let service = claudeAgentService
        Task { await service.stop() }
    }

    /// Drops all conversation state without touching the child process.
    private func clearClaudeConversation() {
        claudeEventTask?.cancel()
        claudeEventTask = nil

        claudeTimeline = []
        claudePendingPermissions = []
        claudeQueuedMessages = []
        claudePendingAttachments = []
        claudePendingContexts = []
        claudeBlockIndex = [:]
        claudeToolIndex = [:]
        claudeSessionInfo = nil
        claudeSlashCommands = []
        claudeSessionCostUSD = 0
        claudeSessionTokens = 0
        claudeIsStreaming = false
        claudeStatus = ""
    }

    /// Switches the active Claude account. Each account is a separate CLI
    /// config root with its own login, so the session restarts from scratch.
    func switchClaudeAccount(_ account: ClaudeAccount) {
        guard account != activeClaudeAccount else { return }
        activeClaudeAccount = account
        newClaudeConversation()
    }

    /// Switches models mid-conversation — no restart, matching the CLI's
    /// `/model` behaviour.
    func setClaudeModel(_ model: ClaudeModelOption) {
        guard model != claudeModel else { return }
        claudeModel = model
        let service = claudeAgentService
        Task { await service.setModel(model) }
        appendClaudeNotice("Model set to \(model.name).", level: .info)
    }

    /// Switches permission mode mid-conversation, like the CLI's Shift+Tab.
    func setClaudePermissionMode(_ mode: ClaudePermissionMode) {
        guard mode != claudePermissionMode else { return }
        claudePermissionMode = mode
        let service = claudeAgentService
        Task { await service.setPermissionMode(mode) }
        appendClaudeNotice("Permission mode: \(mode.title).", level: mode.isDangerous ? .warning : .info)
    }

    /// Loads the resumable conversations for this workspace, for the panel's
    /// history menu.
    func loadClaudeRecentSessions() async {
        guard let root = workspace?.rootURL else {
            claudeRecentSessions = []
            return
        }
        claudeRecentSessions = await claudeSessionStore.recentSessions(
            workspace: root, account: activeClaudeAccount
        )
    }

    /// Reopens a past conversation. The CLI replays its own history, so the
    /// panel starts from a note rather than a reconstructed transcript.
    func resumeClaudeSession(_ session: ClaudeStoredSession) {
        newClaudeConversation(resuming: session.id)
        appendClaudeNotice("Resumed “\(session.displayTitle)”.", level: .info)
    }

    // MARK: - Sending

    /// Sends a turn, starting the session first if it isn't up yet. A message
    /// typed mid-turn is queued and flushed when the agent goes idle.
    func sendClaudeMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = claudePendingAttachments
        let contexts = claudePendingContexts
        guard !trimmed.isEmpty || !attachments.isEmpty || !contexts.isEmpty else { return }

        if claudeSessionInfo == nil && claudeEventTask == nil {
            startClaudeSession()
        }

        claudePendingAttachments = []
        claudePendingContexts = []

        appendClaudeItem(.init(
            id: UUID().uuidString,
            kind: .user(text: trimmed, attachments: attachments, contexts: contexts)
        ))

        let payload = claudePromptPayload(text: trimmed, attachments: attachments, contexts: contexts)

        guard !claudeIsStreaming else {
            claudeQueuedMessages.append(payload)
            return
        }

        claudeIsStreaming = true
        claudeStatus = "Thinking…"
        let service = claudeAgentService
        Task { await service.send(text: payload) }
    }

    /// Interrupts the running turn and drops anything queued behind it.
    func interruptClaude() {
        claudeQueuedMessages = []
        let service = claudeAgentService
        Task { await service.interrupt() }
        claudeStatus = "Interrupting…"
    }

    /// Answers a permission prompt and removes it from the queue.
    func resolveClaudePermission(_ request: ClaudePermissionRequest, decision: ClaudePermissionDecision) {
        claudePendingPermissions.removeAll { $0.id == request.id }
        removeClaudeItem(id: claudePermissionItemId(request.id))

        // Reflect the outcome on the tool row so the transcript reads correctly.
        if let toolUseId = request.toolUseId {
            updateClaudeToolCall(id: toolUseId) { call in
                switch decision {
                case .allowOnce, .allowAlways: call.status = .running
                case .deny:                    call.status = .denied
                }
            }
        }

        let service = claudeAgentService
        Task { await service.respond(to: request, decision: decision) }
    }

    // MARK: - Context attachments

    /// Stages files for the next message — the paperclip button and
    /// drag-and-drop both funnel through here. De-dupes by path.
    func addClaudeAttachments(_ urls: [URL]) {
        for url in urls where !claudePendingAttachments.contains(where: { $0.url == url }) {
            claudePendingAttachments.append(ClaudeAttachment(url: url))
        }
    }

    func removeClaudeAttachment(_ id: UUID) {
        claudePendingAttachments.removeAll { $0.id == id }
    }

    /// Attaches a workspace file (or a range within one) as an `@` mention.
    func addClaudeContext(_ ref: ClaudeContextRef) {
        guard !claudePendingContexts.contains(ref) else { return }
        claudePendingContexts.append(ref)
    }

    func removeClaudeContext(_ id: String) {
        claudePendingContexts.removeAll { $0.id == id }
    }

    /// Attaches the focused editor's file, or its selection when there is one.
    func attachFocusedEditorContext() {
        guard let ref = claudeEditorSelection ?? focusedTabContextRef() else { return }
        addClaudeContext(ref)
        showClaudePanel = true
    }

    /// The focused tab as a whole-file context reference.
    func focusedTabContextRef() -> ClaudeContextRef? {
        guard let url = focusedTab?.fileURL else { return nil }
        return ClaudeContextRef(url: url, lineRange: nil, kind: .file)
    }

    /// Called by the editor as the selection changes so the panel can offer
    /// "add selection" without reaching into the text view itself.
    func setClaudeEditorSelection(url: URL?, startLine: Int, endLine: Int) {
        // Selection changes fire on every caret move, so only write when the
        // value actually differs — an unconditional assignment would
        // invalidate the panel on every keystroke in the editor.
        guard let url, endLine >= startLine else {
            if claudeEditorSelection != nil { claudeEditorSelection = nil }
            return
        }
        let ref = ClaudeContextRef(url: url, lineRange: startLine...endLine, kind: .selection)
        guard ref != claudeEditorSelection else { return }
        claudeEditorSelection = ref
    }

    /// Builds the text actually sent to the agent: `@path` mentions first (the
    /// CLI resolves and reads those itself), then the user's prose, then any
    /// attached files as absolute paths.
    func claudePromptPayload(
        text: String,
        attachments: [ClaudeAttachment],
        contexts: [ClaudeContextRef]
    ) -> String {
        var parts: [String] = []

        if !contexts.isEmpty {
            let root = workspace?.rootURL
            parts.append(contexts.map { $0.promptFragment(relativeTo: root) }.joined(separator: " "))
        }
        if !text.isEmpty {
            parts.append(text)
        }
        if !attachments.isEmpty {
            let lines = attachments.map { "- \($0.url.path)" }.joined(separator: "\n")
            var block = "Attached files:\n\(lines)"
            if attachments.contains(where: \.isVideo) {
                block += "\n\nUse ffmpeg/ffprobe to inspect the attached video file(s) — "
                    + "e.g. `ffmpeg -i <path> -vf fps=1 frame_%04d.png` to extract frames."
            }
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Event application

    /// Folds one agent event into the timeline.
    func apply(_ event: ClaudeAgentEvent) {
        switch event {

        case .sessionInit(let info):
            claudeSessionInfo = info
            claudeStatus = ""

        case .controlResponse(let requestId, let payload):
            guard requestId == "initialize" else { return }
            claudeSlashCommands = ClaudeStreamDecoder.slashCommands(fromInitializePayload: payload)

        case .textUpdated(let blockId, let text, let parent):
            upsertClaudeTextBlock(blockId: blockId, text: text, parent: parent, isThinking: false)

        case .thinkingUpdated(let blockId, let text, let parent):
            upsertClaudeTextBlock(blockId: blockId, text: text, parent: parent, isThinking: true)

        case .blockFinished(let blockId):
            guard let itemId = claudeBlockIndex[blockId],
                  let index = claudeTimeline.firstIndex(where: { $0.id == itemId }) else { return }
            switch claudeTimeline[index].kind {
            case .assistant(let text, _): claudeTimeline[index].kind = .assistant(text: text, isStreaming: false)
            case .thinking(let text, _):  claudeTimeline[index].kind = .thinking(text: text, isStreaming: false)
            default: break
            }

        case .toolStarted(let id, let name, let parent):
            guard claudeToolIndex[id] == nil else { return }
            let itemId = "tool:\(id)"
            claudeToolIndex[id] = itemId
            appendClaudeItem(.init(
                id: itemId,
                kind: .tool(ClaudeToolCall(id: id, name: name, parentToolUseId: parent)),
                parentToolUseId: parent
            ))
            claudeStatus = ""

        case .toolInputUpdated(let id, let input):
            // A tool can be announced by an `assistant` snapshot before any
            // partial frame arrives; create the row on first sight either way.
            if claudeToolIndex[id] == nil {
                let itemId = "tool:\(id)"
                claudeToolIndex[id] = itemId
                appendClaudeItem(.init(id: itemId, kind: .tool(ClaudeToolCall(id: id, name: "Tool"))))
            }
            updateClaudeToolCall(id: id) { call in
                call.input = input
                if call.status == .pending { call.status = .running }
            }

        case .toolResult(let id, let text, let isError):
            updateClaudeToolCall(id: id) { call in
                call.resultText = text
                call.isError = isError
                // A denial already set `.denied`; don't overwrite that nuance.
                if call.status != .denied { call.status = isError ? .failed : .success }
                call.finishedAt = Date()
            }
            noteClaudeFileWrite(toolId: id)

        case .permissionRequest(let request):
            claudePendingPermissions.append(request)
            if let toolUseId = request.toolUseId {
                updateClaudeToolCall(id: toolUseId) { $0.status = .awaitingPermission }
            }
            appendClaudeItem(.init(id: claudePermissionItemId(request.id), kind: .permission(request)))
            claudeStatus = "Waiting for your approval"

        case .permissionDenied(let toolUseId, let reason):
            updateClaudeToolCall(id: toolUseId) { call in
                call.status = .denied
                if call.resultText.isEmpty { call.resultText = reason }
                call.finishedAt = Date()
            }

        case .status(let status):
            claudeStatus = Self.claudeStatusLabel(status)

        case .notice(let text, let level):
            appendClaudeNotice(text, level: level)

        case .turnResult(let result):
            finishClaudeTurn(result)
        }
    }

    // MARK: - Timeline helpers

    private func claudePermissionItemId(_ requestId: String) -> String { "permission:\(requestId)" }

    private func appendClaudeItem(_ item: ClaudeTimelineItem) {
        claudeTimeline.append(item)
    }

    private func removeClaudeItem(id: String) {
        claudeTimeline.removeAll { $0.id == id }
    }

    func appendClaudeNotice(_ text: String, level: ClaudeNoticeLevel) {
        appendClaudeItem(.init(id: UUID().uuidString, kind: .notice(text: text, level: level)))
    }

    /// Creates or updates the timeline row backing one streaming text block.
    private func upsertClaudeTextBlock(blockId: String, text: String, parent: String?, isThinking: Bool) {
        let kind: ClaudeTimelineItem.Kind = isThinking
            ? .thinking(text: text, isStreaming: true)
            : .assistant(text: text, isStreaming: true)

        if let itemId = claudeBlockIndex[blockId],
           let index = claudeTimeline.firstIndex(where: { $0.id == itemId }) {
            claudeTimeline[index].kind = kind
            return
        }

        let itemId = "block:\(blockId)"
        claudeBlockIndex[blockId] = itemId
        appendClaudeItem(.init(id: itemId, kind: kind, parentToolUseId: parent))
        claudeStatus = ""
    }

    /// Mutates a tool row in place, keyed by its `tool_use` id.
    private func updateClaudeToolCall(id: String, _ mutate: (inout ClaudeToolCall) -> Void) {
        guard let itemId = claudeToolIndex[id],
              let index = claudeTimeline.firstIndex(where: { $0.id == itemId }),
              case .tool(var call) = claudeTimeline[index].kind
        else { return }
        mutate(&call)
        claudeTimeline[index].kind = .tool(call)
    }

    /// Closes out a turn: records cost, marks streaming blocks final, and
    /// releases the next queued message.
    private func finishClaudeTurn(_ result: ClaudeTurnResult) {
        claudeSessionCostUSD += result.costUSD
        claudeSessionTokens  += result.outputTokens + result.inputTokens

        for index in claudeTimeline.indices {
            switch claudeTimeline[index].kind {
            case .assistant(let text, true): claudeTimeline[index].kind = .assistant(text: text, isStreaming: false)
            case .thinking(let text, true):  claudeTimeline[index].kind = .thinking(text: text, isStreaming: false)
            default: break
            }
        }

        if result.isError, !result.text.isEmpty {
            appendClaudeNotice(result.text, level: .error)
        }
        // A turn that did real work gets a cost/timing rule under it; a bare
        // one-line answer does not need the furniture.
        if result.costUSD > 0 || result.durationMs > 1500 {
            appendClaudeItem(.init(id: "summary:\(UUID().uuidString)", kind: .summary(result)))
        }

        claudeIsStreaming = false
        claudeStatus = ""
        reloadClaudeTouchedTabs()

        guard !claudeQueuedMessages.isEmpty else { return }
        let next = claudeQueuedMessages.removeFirst()
        claudeIsStreaming = true
        claudeStatus = "Thinking…"
        let service = claudeAgentService
        Task { await service.send(text: next) }
    }

    // MARK: - Editor sync

    /// Files the agent wrote during this turn, so open tabs can be refreshed.
    private func noteClaudeFileWrite(toolId id: String) {
        guard let itemId = claudeToolIndex[id],
              let index = claudeTimeline.firstIndex(where: { $0.id == itemId }),
              case .tool(let call) = claudeTimeline[index].kind,
              call.isMutating, call.status == .success,
              let path = call.filePath
        else { return }
        claudeTouchedPaths.insert(path)
    }

    /// Reloads any open tab the agent edited, so the editor never shows stale
    /// text after a turn. Tabs with unsaved edits are left alone — the
    /// existing external-change banner handles that conflict.
    private func reloadClaudeTouchedTabs() {
        let paths = claudeTouchedPaths
        claudeTouchedPaths = []
        guard !paths.isEmpty else { return }

        for path in paths {
            guard let index = openTabs.firstIndex(where: { $0.fileURL?.path == path }) else { continue }
            guard !openTabs[index].isDirty else {
                openTabs[index].externallyModified = true
                continue
            }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            openTabs[index].content = text
        }
    }

    // MARK: - Formatting

    /// Maps the CLI's terse status codes to panel-facing text.
    static func claudeStatusLabel(_ status: String) -> String {
        switch status {
        case "requesting":  return "Thinking…"
        case "compacting":  return "Compacting context…"
        case "tool_use":    return "Running tools…"
        default:            return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func claudeLaunchFailureText(_ error: Error) -> String {
        switch error {
        case ClaudeAgentError.binaryNotFound(let name):
            return "Couldn't find the `\(name)` CLI. Install Claude Code and make sure it's on your PATH."
        case ClaudeAgentError.launchFailed(let reason):
            return "Couldn't start the Claude agent: \(reason)"
        default:
            return "Couldn't start the Claude agent: \(error.localizedDescription)"
        }
    }
}
