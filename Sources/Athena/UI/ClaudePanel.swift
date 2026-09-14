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
            sessionBar
            Divider()
            timeline
            Divider()
            composer
        }
        .overlay(alignment: .leading) { Divider() }
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

    // MARK: - Session bar

    private var sessionBar: some View {
        HStack(spacing: appState.sf(6)) {
            ForEach(ClaudeAccount.all) { account in
                AccountChip(account: account, isActive: appState.activeClaudeAccount == account) {
                    appState.switchClaudeAccount(account)
                }
            }

            Spacer(minLength: appState.sf(4))

            modelMenu
            permissionModeMenu
            historyMenu

            Button {
                appState.newClaudeConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New conversation")
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(7))
    }

    private var modelMenu: some View {
        Menu {
            ForEach(ClaudeModelOption.all) { option in
                Button {
                    appState.setClaudeModel(option)
                } label: {
                    if option == appState.claudeModel {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            HStack(spacing: appState.sf(3)) {
                Text(appState.claudeModel.name)
                    .font(.system(size: appState.sf(10), weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: appState.sf(7), weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model for this session")
    }

    private var permissionModeMenu: some View {
        Menu {
            ForEach(ClaudePermissionMode.allCases) { mode in
                Button {
                    appState.setClaudePermissionMode(mode)
                } label: {
                    if mode == appState.claudePermissionMode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: appState.sf(3)) {
                Image(systemName: appState.claudePermissionMode.icon)
                    .font(.system(size: appState.sf(9)))
                Text(appState.claudePermissionMode.shortTitle)
                    .font(.system(size: appState.sf(10), weight: .medium))
            }
            .foregroundStyle(appState.claudePermissionMode.isDangerous ? Color.orange : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permission mode")
    }

    /// Past conversations for this workspace, read from the CLI's own
    /// transcript store so the list matches `claude --resume` exactly.
    private var historyMenu: some View {
        Menu {
            if appState.claudeRecentSessions.isEmpty {
                Text("No past conversations")
            } else {
                ForEach(appState.claudeRecentSessions) { session in
                    Button(session.displayTitle) { appState.resumeClaudeSession(session) }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Resume a past conversation")
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
        VStack(spacing: appState.sf(10)) {
            Image(systemName: "sparkles")
                .font(.system(size: appState.sf(28)))
                .foregroundStyle(.tertiary)
            Text("Ask Claude anything")
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(.secondary)
            VStack(spacing: appState.sf(3)) {
                Text("/ for commands · @ to add files")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.tertiary)
                if let info = appState.claudeSessionInfo {
                    Text("\(info.tools.count) tools · \(info.mcpServers.filter(\.isConnected).count) MCP servers")
                        .font(.system(size: appState.sf(10)))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, appState.sf(48))
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
            contextBar
            inputBar
            footer
        }
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
                .padding(.horizontal, appState.sf(10))
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

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: appState.sf(8)) {
            Button(action: presentAttachmentPicker) {
                Image(systemName: "paperclip")
                    .font(.system(size: appState.sf(14)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach files (or drag & drop onto the panel)")

            TextField(placeholder, text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: appState.sf(13)))
                .lineLimit(1...8)
                .focused($inputFocused)
                .onChange(of: inputText) { _, _ in selectedCompletionIndex = 0 }
                .onKeyPress(.upArrow) { moveCompletionSelection(-1) }
                .onKeyPress(.downArrow) { moveCompletionSelection(1) }
                .onKeyPress(.tab) { acceptSelectedCompletion() }
                .onKeyPress(.return) { handleReturn() }
                .onKeyPress(.escape) {
                    guard activeCompletion != nil else { return .ignored }
                    inputText = ""
                    return .handled
                }

            sendButton
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(8))
    }

    private var placeholder: String {
        appState.claudeIsStreaming ? "Queue a follow-up…" : "Message Claude… (/ commands, @ files)"
    }

    private var sendButton: some View {
        Button {
            if appState.claudeIsStreaming && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appState.interruptClaude()
            } else {
                submit()
            }
        } label: {
            Image(systemName: isStopButton ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: appState.sf(20)))
                .foregroundStyle(sendButtonColor)
        }
        .buttonStyle(.plain)
        .disabled(!isStopButton && !canSubmit)
        .help(isStopButton ? "Stop (Esc)" : "Send")
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
        return canSubmit ? .accentColor : .secondary
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: appState.sf(6)) {
            Circle()
                .fill(appState.claudeSessionIsLive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: appState.sf(5), height: appState.sf(5))

            Text(footerLabel)
                .font(.system(size: appState.sf(9)))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if appState.claudeSessionCostUSD > 0 {
                Text(String(format: "$%.3f", appState.claudeSessionCostUSD))
                    .font(.system(size: appState.sf(9), design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Session cost")
            }
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.bottom, appState.sf(6))
    }

    private var footerLabel: String {
        guard let info = appState.claudeSessionInfo else {
            return appState.claudeEventTask == nil ? "Not connected" : "Connecting…"
        }
        let model = info.model.isEmpty ? appState.claudeModel.name : info.model
        return "\(model) · \(URL(fileURLWithPath: info.cwd).lastPathComponent)"
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
        HStack(alignment: .top, spacing: 0) {
            // The caret marks which paragraph is still being written when a
            // turn interleaves prose with tool calls.
            Text(attributed) + Text(isStreaming ? " ▍" : "").foregroundColor(.accentColor)
        }
        .font(.system(size: appState.sf(12.5)))
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
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

    /// Renders inline markdown (bold, code spans, links). Full markdown is
    /// deliberately out of scope here — code blocks arrive as tool calls, and
    /// prose reads better without a heavyweight renderer in a narrow panel.
    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - AccountChip

private struct AccountChip: View {
    @Environment(AppState.self) private var appState

    let account: ClaudeAccount
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(account.name)
                .font(.system(size: appState.sf(10), weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .padding(.horizontal, appState.sf(7))
                .padding(.vertical, appState.sf(3))
                .background(
                    RoundedRectangle(cornerRadius: appState.sf(4))
                        .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help("\(account.name) account")
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
