// DiffViewerView.swift
// Athena — read-only unified diff viewer for a single Git file change.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - DiffViewerView

/// A full-window dimmed overlay presenting one file's unified diff, entered
/// from `GitPanelView`'s row click (plan.md item 18, "D2"). Mirrors
/// `QuickOpenView`'s existing dimmed-backdrop-plus-card overlay pattern
/// (`MainWindowView`'s `.overlay { if appState.showQuickOpen { … } }`) rather
/// than introducing a new presentation mechanism — the smallest architectural
/// footprint for a single-window app, sized larger than the palette since
/// diff content needs room. This is the unified (single-pane) slice only, not
/// the larger side-by-side split-pane view the plan flags as separate "L"
/// effort.
struct DiffViewerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop — tap to dismiss, matching QuickOpenView.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { appState.closeDiffViewer() }

            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
            .frame(width: 920, height: 640)
            .padding(.top, 36)
        }
        .onKeyPress(.escape) { appState.closeDiffViewer(); return .handled }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.diffViewerCommit != nil ? "clock.arrow.circlepath" : "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: appState.sf(13)))

            VStack(alignment: .leading, spacing: 0) {
                Text(primaryTitle)
                    .font(.system(size: appState.sf(13), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !secondaryTitle.isEmpty {
                    Text(secondaryTitle)
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(appState.diffViewerCommit != nil ? .tail : .head)
                }
            }

            Spacer()

            if appState.diffViewerCommit == nil, appState.diffViewerStaged {
                Text("Staged")
                    .font(.system(size: appState.sf(10), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }

            Button {
                appState.closeDiffViewer()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: appState.sf(14)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 40)
    }

    /// The commit's message when opened from `CommitHistoryView`, otherwise
    /// the file change's name.
    private var primaryTitle: String {
        if let commit = appState.diffViewerCommit { return commit.message }
        return fileName
    }

    /// The commit's short hash + author when opened from `CommitHistoryView`,
    /// otherwise the file change's parent directory path.
    private var secondaryTitle: String {
        if let commit = appState.diffViewerCommit {
            return "\(commit.shortHash) · \(commit.author)"
        }
        return parentPath
    }

    private var fileName: String {
        guard let path = appState.diffViewerChange?.path else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var parentPath: String {
        guard let path = appState.diffViewerChange?.path else { return "" }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent == "." ? "" : parent
    }

    /// A commit's diff can span multiple files with different languages, and
    /// `ParsedDiff` doesn't track a file path per hunk, so commit mode falls
    /// back to `.plaintext` rather than guessing from one file.
    private var language: Language {
        guard appState.diffViewerCommit == nil,
              let path = appState.diffViewerChange?.path
        else { return .plaintext }
        return Language.detect(from: URL(fileURLWithPath: path))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appState.diffViewerIsLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = appState.diffViewerErrorMessage {
            placeholder(message)
        } else if appState.diffViewerParsedDiff.isBinary {
            placeholder("Binary file — diff not shown.")
        } else if appState.diffViewerParsedDiff.hunks.isEmpty {
            placeholder("No changes to display.")
        } else {
            let highlighter = SyntaxHighlighter(
                language: language,
                theme: appState.currentTheme,
                fontSize: 12,
                fontLigatures: false
            )
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(appState.diffViewerParsedDiff.hunks.enumerated()), id: \.offset) { _, hunk in
                        DiffHunkView(hunk: hunk, highlighter: highlighter)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: appState.sf(12)))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DiffHunkView

/// One hunk's `@@ … @@` header plus its lines.
private struct DiffHunkView: View {
    @Environment(AppState.self) private var appState

    let hunk: DiffHunk
    let highlighter: SyntaxHighlighter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: appState.sf(11), weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineRowView(line: line, highlighter: highlighter)
            }
        }
    }
}

// MARK: - DiffLineRowView

/// A single diff line: old/new line-number gutters, a `+`/`-`/` ` marker
/// column, and the syntax-highlighted code content, with a green/red
/// background tint for added/removed lines (`EditorTheme.diffAdded`/
/// `.diffRemoved`, following the same themed-color pattern as
/// `diagnosticError`/`diagnosticWarning`).
private struct DiffLineRowView: View {
    @Environment(AppState.self) private var appState

    let line: DiffLine
    let highlighter: SyntaxHighlighter

    private var marker: String {
        switch line.kind {
        case .added:   return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added:   return Color(nsColor: appState.currentTheme.diffAdded)
        case .removed: return Color(nsColor: appState.currentTheme.diffRemoved)
        case .context: return .secondary
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .added:   return Color(nsColor: appState.currentTheme.diffAdded).opacity(0.15)
        case .removed: return Color(nsColor: appState.currentTheme.diffRemoved).opacity(0.15)
        case .context: return .clear
        }
    }

    /// Runs `SyntaxHighlighter` over the line's code content and rebuilds it
    /// as a concatenation of colored `Text` fragments — SwiftUI's `Text`
    /// supports per-segment `.foregroundColor` via `+` concatenation, which
    /// sidesteps needing an `NSAttributedString` → `AttributedString` scope
    /// conversion just to carry the highlighter's per-run colors into
    /// SwiftUI. A truly empty line still highlights a single space so the
    /// row has non-zero height like every other line.
    private var highlightedLine: Text {
        let displayText = line.text.isEmpty ? " " : line.text
        let attributed = highlighter.highlight(displayText)
        let full = NSRange(location: 0, length: attributed.length)

        var fragments: [Text] = []
        attributed.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            let color = (value as? NSColor) ?? appState.currentTheme.foreground
            let substring = (attributed.string as NSString).substring(with: range)
            fragments.append(Text(substring).foregroundColor(Color(nsColor: color)))
        }
        return fragments.reduce(Text("")) { $0 + $1 }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.secondary)

            Text(line.newLineNumber.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)

            Text(marker)
                .frame(width: 14, alignment: .center)
                .foregroundStyle(markerColor)
                .fontWeight(.bold)

            highlightedLine
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 24)
        }
        .font(.system(size: appState.sf(12), design: .monospaced))
        .padding(.vertical, 1)
        .background(rowBackground)
    }
}
