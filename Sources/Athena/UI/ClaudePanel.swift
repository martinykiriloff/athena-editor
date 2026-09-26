// ClaudePanel.swift — Claude Code agent sidebar: session controls, tool
// timeline, permission prompts and the composer.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ClaudePanel

struct ClaudePanel: View {
    @Environment(AppState.self) private var appState

    @State private var inputText: String = ""
    @State private var selectedCompletionIndex: Int = 0
    @State private var isDropTargeted: Bool = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            timeline
            composer
        }
        .overlay(alignment: .leading) { Divider() }
        .claudeDropdownHost()
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: appState.sf(2))
                    .background(Color.accentColor.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in appState.addClaudeAttachments([url]) }
                }
            }
            return true
        }
        .task {
            // Bring the agent up as soon as the panel is first shown, so the
            // command palette and session info are populated before the user
            // types anything.
            if appState.claudeSessionInfo == nil && appState.claudeEventTask == nil {
                appState.startClaudeSession()
            }
        }
    }

    // MARK: - Header

    /// Titled like every sidebar panel so the panel says what it is; session
    /// actions sit on the right, the way VS Code's views place them.
    private var header: some View {
        HStack(spacing: appState.sf(6)) {
            Circle()
                .fill(appState.claudeSessionIsLive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: appState.sf(6), height: appState.sf(6))
                .help(connectionLabel)

            Text("CLAUDE")
                .font(.system(size: appState.sf(11), weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .help(connectionLabel)

            if ClaudeAccount.available.count > 1 {
                accountMenu
            }

            Spacer(minLength: appState.sf(4))

            if appState.claudeSessionInfo?.isBilledPerToken == true, appState.claudeSessionCostUSD > 0 {
                Text(String(format: "$%.2f", appState.claudeSessionCostUSD))
                    .font(.system(size: appState.sf(10)).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(String(format: "Session cost: $%.4f", appState.claudeSessionCostUSD))
            }

            historyMenu

            PanelIconButton(systemImage: "square.and.pencil", help: "New conversation") {
                appState.newClaudeConversation()
            }

            PanelIconButton(systemImage: "xmark", help: "Close Claude (⇧⌘A)") {
                appState.showClaudePanel = false
            }
        }
        .padding(.leading, appState.sf(12))
        .padding(.trailing, appState.sf(6))
        .frame(height: appState.sf(30))
    }

    private var accountMenu: some View {
        ClaudePickerButton(
            label: appState.activeClaudeAccount.name,
            header: "Account",
            options: ClaudeAccount.available.map {
                ClaudePickerOption(id: $0.id, title: $0.name, icon: "person.crop.circle")
            },
            selection: appState.activeClaudeAccount.id,
            width: 200,
            help: "Claude account"
        ) { id in
            guard let account = ClaudeAccount.all.first(where: { $0.id == id }) else { return }
            appState.switchClaudeAccount(account)
        }
    }

    private var connectionLabel: String {
        guard let info = appState.claudeSessionInfo else {
            return appState.claudeEventTask == nil ? "Not connected" : "Connecting…"
        }
        let model = info.model.isEmpty ? appState.claudeModel.name : info.model
        return "Connected · \(model) · \(URL(fileURLWithPath: info.cwd).lastPathComponent)"
    }

    private var modelMenu: some View {
        ClaudePickerButton(
            label: appState.claudeModel.name,
            header: "Model",
            options: ClaudeModelOption.all.map {
                ClaudePickerOption(id: $0.id, title: $0.name, detail: $0.detail, icon: $0.icon)
            },
            selection: appState.claudeModel.id,
            opensUpward: true,
            help: "Model for this session"
        ) { id in
            appState.setClaudeModel(.option(id: id))
        }
    }

    private var permissionModeMenu: some View {
        let current = appState.claudePermissionMode
        return ClaudePickerButton(
            label: current.shortTitle,
            icon: current.icon,
            labelTint: current.isDangerous ? .orange : .secondary,
            header: "Permissions",
            options: ClaudePermissionMode.allCases.map {
                ClaudePickerOption(
                    id: $0, title: $0.title, detail: $0.detail, icon: $0.icon,
                    tint: $0.isDangerous ? .orange : .accentColor
                )
            },
            selection: current,
            opensUpward: true,
            help: "Permission mode — what Claude may do without asking"
        ) { mode in
            appState.setClaudePermissionMode(mode)
        }
    }

    /// Past conversations for this workspace, read from the CLI's own
    /// transcript store so the list matches `claude --resume` exactly.
    private var historyMenu: some View {
        let sessions = appState.claudeRecentSessions
        return ClaudePickerButton(
            icon: "clock.arrow.circlepath",
            header: "Recent conversations",
            options: sessions.map {
                ClaudePickerOption(
                    id: $0.id,
                    title: $0.displayTitle,
                    detail: $0.modifiedAt.formatted(.relative(presentation: .named))
                )
            },
            emptyMessage: "No past conversations",
            width: 300,
            help: "Resume a past conversation"
        ) { id in
            guard let session = sessions.first(where: { $0.id == id }) else { return }
            appState.resumeClaudeSession(session)
        }
        .task(id: appState.claudeSessionGeneration) { await appState.loadClaudeRecentSessions() }
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if appState.claudeTimeline.isEmpty {
                        emptyState
                    } else {
                        ForEach(appState.claudeTimeline) { item in
                            row(for: item)
                                .id(item.id)
                        }
                    }
                    if appState.claudeIsStreaming && !appState.claudeStatus.isEmpty {
                        statusRow
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, appState.sf(8))
            }
            .onChange(of: appState.claudeTimeline.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: appState.claudeTimeline.last?.kind) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func row(for item: ClaudeTimelineItem) -> some View {
        switch item.kind {
        case .user(let text, let attachments, let contexts):
            UserTurnRow(text: text, attachments: attachments, contexts: contexts)

        case .assistant(let text, let isStreaming):
            AssistantTextRow(text: text, isStreaming: isStreaming)

        case .thinking(let text, let isStreaming):
            ClaudeThinkingRow(text: text, isStreaming: isStreaming)

        case .tool(let call):
            ClaudeToolRow(call: call) { path in
                Task { await appState.openFile(URL(fileURLWithPath: path)) }
            }

        case .permission(let request):
            ClaudePermissionCard(request: request) { decision in
                appState.resolveClaudePermission(request, decision: decision)
            }

        case .notice(let text, let level):
            ClaudeNoticeRow(text: text, level: level)

        case .summary(let result):
            ClaudeTurnSummaryRow(result: result)
        }
    }

    private var statusRow: some View {
        HStack(spacing: appState.sf(6)) {
            ProgressView().controlSize(.mini).scaleEffect(0.6)
            Text(appState.claudeStatus)
                .font(.system(size: appState.sf(10.5)))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, appState.sf(14))
        .padding(.vertical, appState.sf(4))
    }

    private var emptyState: some View {
        VStack(spacing: appState.sf(14)) {
            VStack(spacing: appState.sf(6)) {
                Image(systemName: "sparkles")
                    .font(.system(size: appState.sf(26)))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
                Text("What can I help you build?")
                    .font(.system(size: appState.sf(14), weight: .semibold))
                Text("Claude can read, edit and run code in this workspace.")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Starters fill the composer rather than sending, so the user can
            // adjust the prompt first.
            VStack(spacing: appState.sf(6)) {
                ForEach(starterPrompts, id: \.title) { starter in
                    StarterPromptButton(title: starter.title, icon: starter.icon) {
                        useStarter(starter.prompt)
                    }
                }
            }

            VStack(spacing: appState.sf(3)) {
                Text("Type / for commands · @ to attach files")
                    .font(.system(size: appState.sf(10.5)))
                    .foregroundStyle(.tertiary)
                if let info = appState.claudeSessionInfo {
                    Text("\(info.tools.count) tools · \(info.mcpServers.filter(\.isConnected).count) MCP servers")
                        .font(.system(size: appState.sf(10)))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: appState.sf(320))
        .padding(.horizontal, appState.sf(16))
        .padding(.top, appState.sf(36))
        .frame(maxWidth: .infinity)
    }

    private struct StarterPrompt {
        let title: String
        let icon: String
        let prompt: String
    }

    /// File-scoped starters while a file is focused, workspace-scoped otherwise.
    private var starterPrompts: [StarterPrompt] {
        if appState.focusedTab != nil {
            return [
                StarterPrompt(title: "Explain this file", icon: "text.magnifyingglass",
                              prompt: "Explain what this file does and how it fits into the project."),
                StarterPrompt(title: "Find bugs in this file", icon: "ladybug",
                              prompt: "Review this file for bugs and edge cases."),
                StarterPrompt(title: "Write tests for this file", icon: "checkmark.seal",
                              prompt: "Write tests for this file, following the project's existing test conventions."),
            ]
        }
        return [
            StarterPrompt(title: "Explain this codebase", icon: "map",
                          prompt: "Give me an overview of this codebase: its structure, main components and how they fit together."),
            StarterPrompt(title: "Find where to start", icon: "signpost.right",
                          prompt: "I'm new to this project. Where should I start reading, and how do I build and run it?"),
        ]
    }

    private func useStarter(_ prompt: String) {
        if appState.focusedTab != nil, let ref = appState.focusedTabContextRef(),
           !appState.claudePendingContexts.contains(ref) {
            appState.addClaudeContext(ref)
        }
        inputText = prompt
        inputFocused = true
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if let completion = activeCompletion {
                CompletionList(
                    completion: completion,
                    selectedIndex: selectedCompletionIndex,
                    onSelect: accept
                )
                Divider()
            }
            queueBar
            inputCard
        }
    }

    // MARK: Input card

    /// One bordered box holding everything that shapes the next message —
    /// context, text and session options — so it reads as a single control.
    private var inputCard: some View {
        let shape = RoundedRectangle(cornerRadius: appState.sf(8), style: .continuous)

        return VStack(alignment: .leading, spacing: 0) {
            contextBar
            inputField
            composerToolbar
        }
        .background(shape.fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            shape.strokeBorder(
                inputFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.14),
                lineWidth: 1
            )
        )
        .padding(.horizontal, appState.sf(10))
        .padding(.top, appState.sf(6))
        .padding(.bottom, appState.sf(10))
    }

    // MARK: Queue

    @ViewBuilder
    private var queueBar: some View {
        if !appState.claudeQueuedMessages.isEmpty {
            HStack(spacing: appState.sf(6)) {
                Image(systemName: "clock")
                    .font(.system(size: appState.sf(9)))
                Text("\(appState.claudeQueuedMessages.count) message\(appState.claudeQueuedMessages.count == 1 ? "" : "s") queued")
                    .font(.system(size: appState.sf(10)))
                Spacer()
                Button("Clear") { appState.claudeQueuedMessages = [] }
                    .buttonStyle(.plain)
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(Color.accentColor)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, appState.sf(10))
            .padding(.top, appState.sf(6))
        }
    }

    // MARK: Context chips

    @ViewBuilder
    private var contextBar: some View {
        let hasChips = !appState.claudePendingContexts.isEmpty
            || !appState.claudePendingAttachments.isEmpty
            || suggestedContext != nil

        if hasChips {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: appState.sf(6)) {
                    if let suggestion = suggestedContext {
                        Button {
                            appState.addClaudeContext(suggestion)
                        } label: {
                            HStack(spacing: appState.sf(3)) {
                                Image(systemName: "plus")
                                Text(suggestion.label)
                            }
                            .font(.system(size: appState.sf(10)))
                            .padding(.horizontal, appState.sf(6))
                            .padding(.vertical, appState.sf(3))
                            .overlay(
                                RoundedRectangle(cornerRadius: appState.sf(4))
                                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Add the current editor selection as context")
                    }

                    ForEach(appState.claudePendingContexts) { ref in
                        ContextChip(ref: ref) { appState.removeClaudeContext(ref.id) }
                    }

                    ForEach(appState.claudePendingAttachments) { attachment in
                        AttachmentChip(attachment: attachment) {
                            appState.removeClaudeAttachment(attachment.id)
                        }
                    }
                }
                .padding(.horizontal, appState.sf(8))
            }
            .padding(.top, appState.sf(8))
        }
    }

    /// The editor's live selection (or focused file) when it isn't attached yet.
    private var suggestedContext: ClaudeContextRef? {
        guard let ref = appState.claudeEditorSelection ?? appState.focusedTabContextRef() else { return nil }
        return appState.claudePendingContexts.contains(ref) ? nil : ref
    }

    // MARK: Input

    private var inputField: some View {
        TextField(placeholder, text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: appState.sf(13)))
            .lineLimit(2...10)
            .focused($inputFocused)
            .onChange(of: inputText) { _, _ in selectedCompletionIndex = 0 }
            .onKeyPress(.upArrow) { moveCompletionSelection(-1) }
            .onKeyPress(.downArrow) { moveCompletionSelection(1) }
            .onKeyPress(.tab) { acceptSelectedCompletion() }
            .onKeyPress(.return, phases: .down) { press in
                // Modified Return is left to the field so it can break lines.
                guard press.modifiers.isDisjoint(with: [.shift, .option, .command, .control]) else {
                    return .ignored
                }
                return handleReturn()
            }
            .onKeyPress(.escape) { handleEscape() }
            .padding(.horizontal, appState.sf(10))
            .padding(.top, appState.sf(9))
            .padding(.bottom, appState.sf(4))
    }

    private var placeholder: String {
        appState.claudeIsStreaming ? "Queue a follow-up…" : "Ask Claude to explain, fix or build something…"
    }

    /// Attach, permission mode and model live beside the text they apply to;
    /// Send is where the eye ends up after typing.
    private var composerToolbar: some View {
        HStack(spacing: appState.sf(4)) {
            PanelIconButton(systemImage: "paperclip", help: "Attach files (or drag & drop onto the panel)") {
                presentAttachmentPicker()
            }
            permissionModeMenu
            modelMenu

            Spacer(minLength: appState.sf(4))

            sendButton
        }
        .padding(.leading, appState.sf(4))
        .padding(.trailing, appState.sf(6))
        .padding(.bottom, appState.sf(6))
    }

    private var sendButton: some View {
        Button {
            if appState.claudeIsStreaming && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appState.interruptClaude()
            } else {
                submit()
            }
        } label: {
            Image(systemName: isStopButton ? "stop.fill" : "arrow.up")
                .font(.system(size: appState.sf(isStopButton ? 9 : 11), weight: .bold))
                .foregroundStyle(canSubmit || isStopButton ? Color.white : Color.secondary)
                .frame(width: appState.sf(24), height: appState.sf(24))
                .background(Circle().fill(sendButtonColor))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isStopButton && !canSubmit)
        .help(isStopButton ? "Stop (Esc or ⌘.)" : "Send (↩)")
    }

    private var isStopButton: Bool {
        appState.claudeIsStreaming && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !appState.claudePendingContexts.isEmpty
            || !appState.claudePendingAttachments.isEmpty
    }

    private var sendButtonColor: Color {
        if isStopButton { return .red }
        return canSubmit ? .accentColor : Color.secondary.opacity(0.18)
    }

    // MARK: - Completions

    /// What the composer is currently offering, derived from the caret token.
    enum CompletionKind {
        case commands([ClaudeSlashCommand])
        case files([QuickOpenEntry], token: String)

        var count: Int {
            switch self {
            case .commands(let items):   return items.count
            case .files(let items, _):   return items.count
            }
        }
    }

    private var activeCompletion: CompletionKind? {
        // `/command` only counts while it is the whole message — the CLI
        // treats a slash command as the entire turn.
        if inputText.hasPrefix("/"), !inputText.contains(" ") {
            let filter = String(inputText.dropFirst()).lowercased()
            let matches = appState.claudeSlashCommands
                .filter { filter.isEmpty || $0.name.lowercased().contains(filter) }
                .prefix(60)
            return matches.isEmpty ? nil : .commands(Array(matches))
        }

        guard let token = mentionToken else { return nil }
        let entries = matchingFiles(for: token)
        return entries.isEmpty ? nil : .files(entries, token: token)
    }

    /// The `@…` fragment the caret sits in, if any.
    private var mentionToken: String? {
        guard let at = inputText.lastIndex(of: "@") else { return nil }
        let after = inputText[inputText.index(after: at)...]
        guard !after.contains(" "), !after.contains("\n") else { return nil }
        // Only treat it as a mention at a word boundary.
        if at > inputText.startIndex {
            let before = inputText[inputText.index(before: at)]
            guard before == " " || before == "\n" else { return nil }
        }
        return String(after)
    }

    private func matchingFiles(for token: String) -> [QuickOpenEntry] {
        let index = appState.quickOpenIndex
        guard !index.isEmpty else { return [] }
        guard !token.isEmpty else { return Array(index.prefix(20)) }

        return index
            .compactMap { entry -> (QuickOpenEntry, Int)? in
                guard let score = fuzzyNameScore(query: token, target: entry.relativePath) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(20)
            .map(\.0)
    }

    private func moveCompletionSelection(_ delta: Int) -> KeyPress.Result {
        guard let completion = activeCompletion, completion.count > 0 else { return .ignored }
        selectedCompletionIndex = (selectedCompletionIndex + delta + completion.count) % completion.count
        return .handled
    }

    private func acceptSelectedCompletion() -> KeyPress.Result {
        guard let completion = activeCompletion else { return .ignored }
        switch completion {
        case .commands(let items):
            guard items.indices.contains(selectedCompletionIndex) else { return .ignored }
            accept(.command(items[selectedCompletionIndex]))
        case .files(let items, _):
            guard items.indices.contains(selectedCompletionIndex) else { return .ignored }
            accept(.file(items[selectedCompletionIndex]))
        }
        return .handled
    }

    /// Esc closes an open picker first, then stops a running turn — matching
    /// the Stop button's tooltip.
    private func handleEscape() -> KeyPress.Result {
        if activeCompletion != nil {
            inputText = ""
            return .handled
        }
        guard appState.claudeIsStreaming else { return .ignored }
        appState.interruptClaude()
        return .handled
    }

    private func handleReturn() -> KeyPress.Result {
        if activeCompletion != nil { return acceptSelectedCompletion() }
        guard canSubmit else { return .ignored }
        submit()
        return .handled
    }

    /// One accepted completion.
    enum CompletionChoice {
        case command(ClaudeSlashCommand)
        case file(QuickOpenEntry)
    }

    private func accept(_ choice: CompletionChoice) {
        switch choice {
        case .command(let command):
            // Leave the trailing space so an argument hint can be typed
            // straight away; commands without arguments send as-is.
            inputText = command.argumentHint.isEmpty ? command.trigger : command.trigger + " "

        case .file(let entry):
            appState.addClaudeContext(ClaudeContextRef(url: entry.file.url, lineRange: nil, kind: .file))
            // Drop the `@token` — the chip now represents it.
            if let at = inputText.lastIndex(of: "@") {
                inputText = String(inputText[inputText.startIndex..<at])
            }
        }
        selectedCompletionIndex = 0
    }

    // MARK: - Actions

    private func submit() {
        let text = inputText
        inputText = ""
        selectedCompletionIndex = 0
        appState.sendClaudeMessage(text)
    }

    private func presentAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Attach Files to Claude"
        panel.message = "Choose files to attach — images, video, documents or code."

        guard panel.runModal() == .OK else { return }
        appState.addClaudeAttachments(panel.urls)
    }
}

// MARK: - CompletionList

/// The `/command` and `@file` picker shown above the composer.
private struct CompletionList: View {
    @Environment(AppState.self) private var appState

    let completion: ClaudePanel.CompletionKind
    let selectedIndex: Int
    let onSelect: (ClaudePanel.CompletionChoice) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch completion {
                    case .commands(let commands):
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            commandRow(command, isSelected: index == selectedIndex)
                                .id(command.id)
                        }
                    case .files(let entries, _):
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            fileRow(entry, isSelected: index == selectedIndex)
                                .id(entry.id)
                        }
                    }
                }
            }
            .frame(maxHeight: appState.sf(260))
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: selectedIndex) { _, _ in
                guard let id = selectedId else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private var selectedId: String? {
        switch completion {
        case .commands(let items): return items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
        case .files(let items, _): return items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
        }
    }

    private func commandRow(_ command: ClaudeSlashCommand, isSelected: Bool) -> some View {
        Button {
            onSelect(.command(command))
        } label: {
            HStack(spacing: appState.sf(8)) {
                Text(command.trigger)
                    .font(.system(size: appState.sf(11), design: .monospaced))
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                Text(command.description)
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, appState.sf(10))
            .padding(.vertical, appState.sf(4))
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func fileRow(_ entry: QuickOpenEntry, isSelected: Bool) -> some View {
        Button {
            onSelect(.file(entry))
        } label: {
            HStack(spacing: appState.sf(8)) {
                Image(systemName: "doc")
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.secondary)
                Text(entry.name)
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.primary)
                Text(entry.relativePath)
                    .font(.system(size: appState.sf(9.5)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, appState.sf(10))
            .padding(.vertical, appState.sf(4))
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - UserTurnRow

private struct UserTurnRow: View {
    @Environment(AppState.self) private var appState

    let text: String
    let attachments: [ClaudeAttachment]
    let contexts: [ClaudeContextRef]

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(5)) {
            if !contexts.isEmpty || !attachments.isEmpty {
                HStack(spacing: appState.sf(4)) {
                    ForEach(contexts) { ref in
                        tag(ref.label, icon: ref.kind == .selection ? "text.viewfinder" : "doc")
                    }
                    ForEach(attachments) { attachment in
                        tag(attachment.fileName, icon: "paperclip")
                    }
                    Spacer(minLength: 0)
                }
            }

            if !text.isEmpty {
                Text(text)
                    .font(.system(size: appState.sf(12.5)))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: appState.sf(8)))
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(4))
    }

    private func tag(_ label: String, icon: String) -> some View {
        HStack(spacing: appState.sf(3)) {
            Image(systemName: icon).font(.system(size: appState.sf(8)))
            Text(label).font(.system(size: appState.sf(9.5)))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, appState.sf(5))
        .padding(.vertical, appState.sf(2))
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: appState.sf(3)))
    }
}

// MARK: - AssistantTextRow

private struct AssistantTextRow: View {
    @Environment(AppState.self) private var appState

    let text: String
    let isStreaming: Bool

    var body: some View {
        let blocks = ClaudeMarkdownBlock.parse(text)

        VStack(alignment: .leading, spacing: appState.sf(6)) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, showsCaret: isStreaming && index == blocks.count - 1)
            }
            if isStreaming && blocks.isEmpty {
                caret
            }
        }
        .font(.system(size: appState.sf(12.5)))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, appState.sf(12))
        .padding(.vertical, appState.sf(4))
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private func view(for block: ClaudeMarkdownBlock, showsCaret: Bool) -> some View {
        switch block {
        case .paragraph(let source):
            prose(source, showsCaret: showsCaret)

        case .heading(let level, let source):
            prose(source, showsCaret: showsCaret)
                .font(.system(size: appState.sf(level <= 1 ? 14.5 : level == 2 ? 13.5 : 12.5), weight: .semibold))
                .padding(.top, appState.sf(4))

        case .listItem(let marker, let source):
            HStack(alignment: .firstTextBaseline, spacing: appState.sf(6)) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: appState.sf(12), alignment: .trailing)
                prose(source, showsCaret: showsCaret)
            }

        case .code(let source):
            // The caret is omitted inside code: it would read as code.
            ClaudeCodeBlock(text: source, tint: .primary, lineLimit: 40)
        }
    }

    /// The caret marks which paragraph is still being written when a turn
    /// interleaves prose with tool calls.
    private func prose(_ source: String, showsCaret: Bool) -> some View {
        (Text(Self.inline(source)) + (showsCaret ? caretText : Text("")))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var caretText: Text { Text(" ▍").foregroundColor(.accentColor) }
    private var caret: some View { caretText }

    /// Inline markdown (bold, italics, code spans, links) within one block.
    private static func inline(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

// MARK: - ClaudeMarkdownBlock

/// The block-level markdown Claude's replies actually use — fenced code,
/// headings, list items and paragraphs. Tables and quotes stay as prose.
enum ClaudeMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(marker: String, text: String)
    case code(String)

    static func parse(_ text: String) -> [ClaudeMarkdownBlock] {
        var blocks: [ClaudeMarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]? = nil

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
            } else {
                paragraph.append(line)
            }
        }

        flushParagraph()
        // A fence still open mid-stream renders as code so far.
        if let open = code {
            blocks.append(.code(open.joined(separator: "\n")))
        }
        return blocks
    }

    private static func heading(_ line: String) -> ClaudeMarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    /// `- x`, `* x`, `+ x` and `1. x`, keeping nesting as leading indent.
    private static func listItem(_ line: String) -> ClaudeMarkdownBlock? {
        let indentWidth = line.prefix { $0 == " " }.count
        let indent = String(repeating: "  ", count: indentWidth / 2)
        let trimmed = line.drop { $0 == " " }

        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            return .listItem(marker: indent + "•", text: String(trimmed.dropFirst(2)))
        }

        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .listItem(marker: indent + digits + ".", text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }
}

// MARK: - PanelIconButton

/// Icon-only header/toolbar button with the same hover circle as the
/// picker triggers, so every control in the panel reads as clickable.
private struct PanelIconButton: View {
    @Environment(AppState.self) private var appState

    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(.secondary)
                .frame(width: appState.sf(22), height: appState.sf(22))
                .background(Circle().fill(Color.primary.opacity(isHovered ? 0.07 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - StarterPromptButton

private struct StarterPromptButton: View {
    @Environment(AppState.self) private var appState

    let title: String
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: appState.sf(7), style: .continuous)

        Button(action: action) {
            HStack(spacing: appState.sf(8)) {
                Image(systemName: icon)
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: appState.sf(16))
                Text(title)
                    .font(.system(size: appState.sf(11.5)))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, appState.sf(10))
            .padding(.vertical, appState.sf(7))
            .background(shape.fill(Color.primary.opacity(isHovered ? 0.07 : 0.035)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - ContextChip

private struct ContextChip: View {
    @Environment(AppState.self) private var appState

    let ref: ClaudeContextRef
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: appState.sf(4)) {
            Image(systemName: ref.kind == .selection ? "text.viewfinder" : "doc")
                .font(.system(size: appState.sf(9)))
            Text(ref.label)
                .font(.system(size: appState.sf(10)))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: appState.sf(7), weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, appState.sf(6))
        .padding(.vertical, appState.sf(3))
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: appState.sf(4)))
    }
}

// MARK: - AttachmentChip

private struct AttachmentChip: View {
    @Environment(AppState.self) private var appState

    let attachment: ClaudeAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: appState.sf(4)) {
            Image(systemName: attachment.iconName)
                .font(.system(size: appState.sf(9)))
            Text(attachment.fileName)
                .font(.system(size: appState.sf(10)))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: appState.sf(7), weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, appState.sf(6))
        .padding(.vertical, appState.sf(3))
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: appState.sf(4)))
    }
}
