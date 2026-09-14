// ClaudeTimelineRows.swift
// Athena — row views for the Claude panel timeline (tools, diffs, permissions).
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - ClaudeToolRow

/// A single tool call: a one-line header that expands into the call's body
/// (command, diff, checklist) and its result.
struct ClaudeToolRow: View {
    @Environment(AppState.self) private var appState

    let call: ClaudeToolCall
    /// Opens a file the call touched in the editor.
    var onOpenFile: (String) -> Void = { _ in }

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                body_
                    .padding(.leading, appState.sf(24))
                    .padding(.trailing, appState.sf(10))
                    .padding(.bottom, appState.sf(6))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: appState.sf(6))
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(alignment: .leading) {
            // Subagent calls get a rail so nested work reads as nested.
            if call.parentToolUseId != nil {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: appState.sf(2))
            }
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(2))
    }

    // MARK: Header

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: appState.sf(6)) {
                statusGlyph
                    .frame(width: appState.sf(14))

                Text(call.displayName)
                    .font(.system(size: appState.sf(11), weight: .medium))
                    .foregroundStyle(.primary)

                if !call.summary.isEmpty {
                    Text(call.summary)
                        .font(.system(size: appState.sf(11), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: appState.sf(4))

                if let duration = call.duration, duration > 0.6 {
                    Text(Self.durationText(duration))
                        .font(.system(size: appState.sf(9)))
                        .foregroundStyle(.tertiary)
                }

                if hasDisclosure {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: appState.sf(8), weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, appState.sf(8))
            .padding(.vertical, appState.sf(5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasDisclosure)
        .contextMenu {
            if let path = call.filePath {
                Button("Open \(ClaudeToolCall.shortPath(path))") { onOpenFile(path) }
            }
            Button("Copy tool input") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(call.input.displayText, forType: .string)
            }
            if !call.resultText.isEmpty {
                Button("Copy result") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(call.resultText, forType: .string)
                }
            }
        }
    }

    private var hasDisclosure: Bool {
        if case .none = call.detail { return !call.resultText.isEmpty }
        return true
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch call.status {
        case .pending, .running:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
        case .awaitingPermission:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(.orange)
        case .success:
            Image(systemName: call.icon)
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(.orange)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(.red)
        }
    }

    // MARK: Body

    @ViewBuilder
    private var body_: some View {
        VStack(alignment: .leading, spacing: appState.sf(6)) {
            switch call.detail {
            case .none:
                EmptyView()
            case .code(let text) where !text.isEmpty:
                ClaudeCodeBlock(text: text)
            case .code:
                EmptyView()
            case .diff(let old, let new):
                ClaudeDiffBlock(old: old, new: new)
            case .todos(let items):
                ClaudeTodoList(items: items)
            }

            if !call.resultText.isEmpty {
                ClaudeCodeBlock(
                    text: call.resultText,
                    tint: call.isError ? .red : nil,
                    lineLimit: 24
                )
            }
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(format: "%.1fs", seconds)
            : String(format: "%dm %ds", Int(seconds) / 60, Int(seconds) % 60)
    }
}

// MARK: - ClaudeCodeBlock

/// Monospaced, scrollable, truncated-with-disclosure text — used for commands,
/// tool output and file contents.
struct ClaudeCodeBlock: View {
    @Environment(AppState.self) private var appState

    let text: String
    var tint: Color? = nil
    var lineLimit: Int = 12

    @State private var showAll = false

    private var lines: [String] { text.components(separatedBy: .newlines) }
    private var isTruncated: Bool { lines.count > lineLimit }

    private var displayed: String {
        guard isTruncated, !showAll else { return text }
        return lines.prefix(lineLimit).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(2)) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(displayed)
                    .font(.system(size: appState.sf(10.5), design: .monospaced))
                    .foregroundStyle(tint ?? .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isTruncated {
                Button(showAll ? "Show less" : "Show \(lines.count - lineLimit) more lines") {
                    showAll.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: appState.sf(9.5)))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(appState.sf(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: appState.sf(4)))
    }
}

// MARK: - ClaudeDiffBlock

/// A unified before/after view of an `Edit`, coloured like the editor's own
/// diff gutter so a proposed change reads at a glance.
struct ClaudeDiffBlock: View {
    @Environment(AppState.self) private var appState

    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: appState.sf(4)) {
                    Text(row.marker)
                        .font(.system(size: appState.sf(10.5), design: .monospaced))
                        .foregroundStyle(row.color)
                        .frame(width: appState.sf(10), alignment: .leading)
                    Text(row.text.isEmpty ? " " : row.text)
                        .font(.system(size: appState.sf(10.5), design: .monospaced))
                        .foregroundStyle(row.isChange ? .primary : .secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, appState.sf(4))
                .padding(.vertical, appState.sf(0.5))
                .background(row.color.opacity(row.isChange ? 0.12 : 0))
            }
        }
        .padding(.vertical, appState.sf(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: appState.sf(4)))
    }

    // MARK: Diff rows

    private struct Row {
        let marker: String
        let text: String
        let color: Color
        let isChange: Bool
    }

    /// Removals then additions, with the shared head/tail collapsed away so a
    /// one-line change in a long block doesn't render as a wall of red/green.
    private var rows: [Row] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: .newlines)
        let newLines = new.isEmpty ? [] : new.components(separatedBy: .newlines)

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        // Keep up to two lines of shared context on each side.
        let headContext = max(0, prefix - 2)
        let contextHead = Array(oldLines[headContext..<prefix])
        let tailEnd = min(oldLines.count, oldLines.count - suffix + 2)
        let contextTail = Array(oldLines[(oldLines.count - suffix)..<tailEnd])

        var result: [Row] = []
        if headContext > 0 {
            result.append(Row(marker: "", text: "⋯", color: .secondary, isChange: false))
        }
        result += contextHead.map { Row(marker: " ", text: $0, color: .secondary, isChange: false) }
        result += oldLines[prefix..<(oldLines.count - suffix)]
            .map { Row(marker: "-", text: $0, color: .red, isChange: true) }
        result += newLines[prefix..<(newLines.count - suffix)]
            .map { Row(marker: "+", text: $0, color: .green, isChange: true) }
        result += contextTail.map { Row(marker: " ", text: $0, color: .secondary, isChange: false) }
        if tailEnd < oldLines.count {
            result.append(Row(marker: "", text: "⋯", color: .secondary, isChange: false))
        }
        return result
    }
}

// MARK: - ClaudeTodoList

/// `TodoWrite`'s plan, rendered as the checklist it is.
struct ClaudeTodoList: View {
    @Environment(AppState.self) private var appState

    let items: [ClaudeTodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(3)) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: appState.sf(6)) {
                    Image(systemName: glyph(for: item))
                        .font(.system(size: appState.sf(10)))
                        .foregroundStyle(item.isDone ? Color.green : item.isInProgress ? Color.accentColor : Color.secondary)
                    Text(item.content)
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                        .strikethrough(item.isDone, color: .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func glyph(for item: ClaudeTodoItem) -> String {
        if item.isDone { return "checkmark.circle.fill" }
        if item.isInProgress { return "arrow.triangle.2.circlepath" }
        return "circle"
    }
}

// MARK: - ClaudePermissionCard

/// The Allow / Always allow / Deny prompt raised by a `can_use_tool` control
/// request — the panel's equivalent of the CLI's permission dialog.
struct ClaudePermissionCard: View {
    @Environment(AppState.self) private var appState

    let request: ClaudePermissionRequest
    let onDecision: (ClaudePermissionDecision) -> Void

    @State private var isDenying = false
    @State private var denyMessage = ""
    @FocusState private var denyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(8)) {
            HStack(spacing: appState.sf(6)) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.orange)
                Text("Allow \(request.displayName)?")
                    .font(.system(size: appState.sf(12), weight: .semibold))
                Spacer()
            }

            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: appState.sf(10.5)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            preview

            if isDenying {
                denyEditor
            } else {
                buttons
            }
        }
        .padding(appState.sf(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: appState.sf(8)))
        .overlay(
            RoundedRectangle(cornerRadius: appState.sf(8))
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(4))
    }

    // MARK: Preview of what is being approved

    @ViewBuilder
    private var preview: some View {
        let call = request.previewCall
        switch call.detail {
        case .code(let text) where !text.isEmpty:
            ClaudeCodeBlock(text: text, lineLimit: 10)
        case .diff(let old, let new):
            ClaudeDiffBlock(old: old, new: new)
        default:
            if !call.summary.isEmpty {
                Text(call.summary)
                    .font(.system(size: appState.sf(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    // MARK: Actions

    private var buttons: some View {
        VStack(alignment: .leading, spacing: appState.sf(6)) {
            HStack(spacing: appState.sf(6)) {
                Button("Allow") { onDecision(.allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)

                Button("Deny") { isDenying = true; denyFocused = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()
            }

            // "Always allow" comes straight from the CLI's own rule
            // suggestions, so approving here writes the same settings entry
            // the terminal client would.
            ForEach(request.suggestions) { suggestion in
                Button {
                    onDecision(.allowAlways(suggestion: suggestion))
                } label: {
                    HStack(spacing: appState.sf(4)) {
                        Image(systemName: "checkmark.shield")
                        Text(suggestion.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: appState.sf(10.5)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var denyEditor: some View {
        VStack(alignment: .leading, spacing: appState.sf(6)) {
            TextField("Tell Claude what to do instead (optional)", text: $denyMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: appState.sf(11)))
                .lineLimit(1...4)
                .focused($denyFocused)
                .onSubmit { submitDenial() }

            HStack(spacing: appState.sf(6)) {
                Button("Send denial") { submitDenial() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { isDenying = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private func submitDenial() {
        let trimmed = denyMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        onDecision(.deny(message: trimmed.isEmpty ? nil : trimmed))
    }
}

// MARK: - ClaudeNoticeRow

struct ClaudeNoticeRow: View {
    @Environment(AppState.self) private var appState

    let text: String
    let level: ClaudeNoticeLevel

    var body: some View {
        HStack(alignment: .top, spacing: appState.sf(6)) {
            Image(systemName: glyph)
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: appState.sf(10.5)))
                .foregroundStyle(level == .info ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(appState.sf(8))
        .background(tint.opacity(level == .info ? 0.06 : 0.12), in: RoundedRectangle(cornerRadius: appState.sf(6)))
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(2))
    }

    private var glyph: String {
        switch level {
        case .info:    return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error:   return "xmark.octagon"
        }
    }

    private var tint: Color {
        switch level {
        case .info:    return .secondary
        case .warning: return .orange
        case .error:   return .red
        }
    }
}

// MARK: - ClaudeThinkingRow

/// Extended thinking, collapsed by default — present but never in the way.
struct ClaudeThinkingRow: View {
    @Environment(AppState.self) private var appState

    let text: String
    let isStreaming: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(4)) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: appState.sf(5)) {
                    Image(systemName: "brain")
                        .font(.system(size: appState.sf(9.5)))
                    Text(isStreaming ? "Thinking…" : "Thought process")
                        .font(.system(size: appState.sf(10), weight: .medium))
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: appState.sf(7.5), weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.system(size: appState.sf(10.5)))
                    .foregroundStyle(.secondary)
                    .italic()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, appState.sf(14))
            }
        }
        .padding(.horizontal, appState.sf(12))
        .padding(.vertical, appState.sf(3))
    }
}

// MARK: - ClaudeTurnSummaryRow

/// Cost and token accounting for one completed turn.
struct ClaudeTurnSummaryRow: View {
    @Environment(AppState.self) private var appState

    let result: ClaudeTurnResult

    var body: some View {
        HStack(spacing: appState.sf(8)) {
            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
            Text(label)
                .font(.system(size: appState.sf(9)))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
        }
        .padding(.horizontal, appState.sf(12))
        .padding(.vertical, appState.sf(6))
    }

    private var label: String {
        var parts: [String] = []
        if result.durationMs > 0 {
            parts.append(String(format: "%.1fs", Double(result.durationMs) / 1000))
        }
        if result.outputTokens > 0 {
            parts.append("\(result.outputTokens.formatted()) out")
        }
        if result.costUSD > 0 {
            parts.append(String(format: "$%.4f", result.costUSD))
        }
        return parts.isEmpty ? "Done" : parts.joined(separator: " · ")
    }
}
