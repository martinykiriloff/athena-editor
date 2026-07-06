// ChatView.swift
// Athena — Claude AI chat panel (bottom panel).
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - ChatView

struct ChatView: View {
    @Environment(AppState.self) private var appState

    @State private var inputText: String = ""
    @State private var useContext: Bool = true
    @FocusState private var inputFocused: Bool
    @State private var apiKeyMissing: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // 1. Header
            chatHeader

            Divider()

            // 2. API key missing notice
            if apiKeyMissing {
                missingKeyBanner
            } else {
                // 3. Message list
                messageList

                Divider()

                // 4. Input area
                inputArea
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(.purple)

            Text("CLAUDE")
                .font(.system(size: appState.sf(11), weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            Spacer()

            // Clear conversation
            if !appState.chatMessages.isEmpty {
                Button {
                    appState.chatMessages.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear conversation")
            }

            // New session
            Button {
                appState.chatMessages.removeAll()
                apiKeyMissing = false
                inputText = ""
            } label: {
                Image(systemName: "plus.square")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New session")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 32)
    }

    // MARK: - Missing Key Banner

    private var missingKeyBanner: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.slash")
                .font(.system(size: appState.sf(28)))
                .foregroundStyle(.tertiary)
            Text("Set Claude API key in Settings")
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                // Post notification or open settings — use NSApp.sendAction pattern
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(appState.chatMessages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if appState.isStreaming {
                        HStack {
                            TypingIndicator()
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .id("typing-indicator")
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
            }
            .onChange(of: appState.chatMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    if appState.isStreaming {
                        proxy.scrollTo("typing-indicator", anchor: .bottom)
                    } else if let last = appState.chatMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: appState.isStreaming) { _, streaming in
                if !streaming, let last = appState.chatMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                // Multiline text editor
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $inputText)
                        .font(.system(size: appState.sf(13)))
                        .frame(minHeight: 36, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .focused($inputFocused)

                    if inputText.isEmpty {
                        Text("Ask Claude…")
                            .font(.system(size: appState.sf(13)))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(inputFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25), lineWidth: 1)
                )

                // Send button
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: appState.sf(22)))
                        .foregroundStyle(
                            canSend ? Color.accentColor : Color.secondary.opacity(0.4)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (Cmd+Return)")
                .keyboardShortcut(.return, modifiers: .command)
            }

            // Bottom meta row
            HStack {
                Text(useContext ? "Context: active file + selection" : "No context")
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.tertiary)

                Toggle("", isOn: $useContext)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .help("Include editor context")

                Spacer()

                let count = inputText.count
                Text("\(count)")
                    .font(.system(size: appState.sf(10), design: .monospaced))
                    .foregroundStyle(count > 4000 ? Color.orange : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appState.isStreaming
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            // Check API key first
            let key = await appState.settingsService.claudeApiKey()
            guard !key.isEmpty else {
                apiKeyMissing = true
                return
            }
            apiKeyMissing = false

            // Build context prefix if enabled
            var userContent = trimmed
            if useContext, let tab = appState.focusedTab {
                var contextParts: [String] = []
                contextParts.append("File: \(tab.title)")
                if !tab.content.isEmpty {
                    // Include a reasonable excerpt (first 200 lines)
                    let lines = tab.content.components(separatedBy: .newlines)
                    let excerpt = lines.prefix(200).joined(separator: "\n")
                    contextParts.append("```\(tab.language.rawValue)\n\(excerpt)\n```")
                }
                userContent = contextParts.joined(separator: "\n") + "\n\n" + trimmed
            }

            // Append user message
            let userMsg = ChatMessage(role: .user, content: trimmed)
            appState.chatMessages.append(userMsg)

            // Clear input
            inputText = ""

            // Append empty assistant message placeholder
            let assistantMsg = ChatMessage(role: .assistant, content: "")
            appState.chatMessages.append(assistantMsg)
            let assistantId = assistantMsg.id

            // Stream
            appState.isStreaming = true
            var accumulated = ""

            do {
                let stream = await appState.claudeService.send(
                    userContent,
                    apiKey: key,
                    systemPrompt: "You are a coding assistant embedded in Athena, a developer IDE. Be concise and accurate. Format code in markdown fenced blocks."
                )

                for try await chunk in stream {
                    accumulated += chunk
                    // Update the assistant message in-place
                    if let idx = appState.chatMessages.firstIndex(where: { $0.id == assistantId }) {
                        appState.chatMessages[idx].content = accumulated
                    }
                }
            } catch {
                if accumulated.isEmpty {
                    if let idx = appState.chatMessages.firstIndex(where: { $0.id == assistantId }) {
                        appState.chatMessages[idx].content = "_Error: \(error.localizedDescription)_"
                    }
                }
            }

            appState.isStreaming = false
        }
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: ChatMessage
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userBubble
            case .assistant:
                assistantBubble
            }
        }
    }

    // MARK: User bubble (right-aligned)

    private var userBubble: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 40)
            Text(message.content)
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor)
                .cornerRadius(12)
        }
    }

    // MARK: Assistant bubble (left-aligned)

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 0) {
            AssistantContent(content: message.content)
            Spacer(minLength: 40)
        }
    }
}

// MARK: - AssistantContent

/// Renders assistant content with simple code-block detection.
private struct AssistantContent: View {
    let content: String
    @Environment(AppState.self) private var appState

    var body: some View {
        if content.isEmpty {
            Color.clear.frame(height: 1)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(parsedSegments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let t):
                        Text(t)
                            .font(.system(size: appState.sf(13)))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .code(let lang, let code):
                        VStack(alignment: .leading, spacing: 0) {
                            if !lang.isEmpty {
                                Text(lang)
                                    .font(.system(size: appState.sf(10), weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 5)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(code)
                                    .font(.system(size: appState.sf(12), design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
        }
    }

    // MARK: Parsing

    private enum Segment {
        case text(String)
        case code(lang: String, code: String)
    }

    private var parsedSegments: [Segment] {
        guard content.contains("```") else {
            return [.text(content)]
        }

        var segments: [Segment] = []
        var remaining = content

        while let fenceStart = remaining.range(of: "```") {
            // Text before the code fence
            let before = String(remaining[remaining.startIndex..<fenceStart.lowerBound])
            if !before.isEmpty {
                segments.append(.text(before))
            }

            // Advance past opening fence
            remaining = String(remaining[fenceStart.upperBound...])

            // Extract optional language identifier (up to newline)
            let lang: String
            if let nlRange = remaining.range(of: "\n") {
                lang = String(remaining[remaining.startIndex..<nlRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                remaining = String(remaining[nlRange.upperBound...])
            } else {
                lang = ""
            }

            // Find closing fence
            if let closingFence = remaining.range(of: "```") {
                let code = String(remaining[remaining.startIndex..<closingFence.lowerBound])
                segments.append(.code(lang: lang, code: code))
                remaining = String(remaining[closingFence.upperBound...])
                // Skip leading newline after closing fence
                if remaining.hasPrefix("\n") {
                    remaining = String(remaining.dropFirst())
                }
            } else {
                // Unclosed fence — treat rest as code (streaming in progress)
                segments.append(.code(lang: lang, code: remaining))
                remaining = ""
            }
        }

        // Any remaining plain text
        if !remaining.isEmpty {
            segments.append(.text(remaining))
        }

        return segments
    }
}

// MARK: - TypingIndicator

struct TypingIndicator: View {
    @State private var phase: Int = 0

    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == index ? 1.0 : 0.3)
                    .scaleEffect(phase == index ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: phase)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
