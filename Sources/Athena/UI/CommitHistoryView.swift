// CommitHistoryView.swift
// Athena — commit history browser for the Source Control panel.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - CommitHistoryView

/// Read-only list of the workspace's recent commits (`git log`, via
/// `AppState.refreshCommitHistory()`), swapped into `GitPanelView` by its
/// History toggle (plan.md item 20 point 2, "D6"). Clicking a commit reuses
/// `DiffViewerView` — via `AppState.openDiffViewer(forCommit:)` — instead of
/// a second diff renderer.
struct CommitHistoryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if let path = appState.commitHistoryPath {
                fileFilterBar(path)
                Divider()
            } else if let label = appState.gitExtras.lineHistoryLabel {
                scopeBar(icon: "text.line.first.and.arrowtriangle.forward", label: "Line \(label)") {
                    Task { await appState.clearLineHistory() }
                }
                Divider()
            }
            toolbar
            Divider()
            historyContent
        }
        .onAppear {
            Task { await appState.refreshCommitHistory() }
        }
    }

    /// "File History" scope chip — the history below is one file's.
    private func fileFilterBar(_ path: String) -> some View {
        HStack(spacing: appState.sf(6)) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button {
                Task { await appState.clearFileHistoryFilter() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show whole-repository history")
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(5))
    }

    private func scopeBar(icon: String, label: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: appState.sf(6)) {
            Image(systemName: icon)
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(5))
    }

    /// Graph toggle and "history of the cursor line".
    private var toolbar: some View {
        HStack(spacing: appState.sf(10)) {
            Toggle("Graph", isOn: Binding(
                get: { appState.gitExtras.showGraph },
                set: { on in Task { await appState.setGraphMode(on) } }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: appState.sf(11)))
            .help("Show all branches as a lane graph")
            Spacer()
            Button("Line History") { Task { await appState.showLineHistoryForCursor() } }
                .buttonStyle(.link)
                .font(.system(size: appState.sf(11)))
                .disabled(appState.focusedTab?.fileURL == nil)
                .help("Commits that changed the line the cursor is on")
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(4))
    }

    @ViewBuilder
    private var historyContent: some View {
        Group {
            if appState.isLoadingCommitHistory {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = appState.commitHistoryErrorMessage {
                placeholder(message)
            } else if appState.commitHistory.isEmpty {
                placeholder("No commits yet.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let rows = appState.gitExtras.graphRows
                        let maxLanes = rows.map(\.laneCount).max() ?? 1
                        ForEach(Array(appState.commitHistory.enumerated()), id: \.element.id) { index, commit in
                            HStack(spacing: 0) {
                                if rows.indices.contains(index) {
                                    CommitGraphLaneView(row: rows[index], maxLanes: maxLanes, height: appState.sf(44))
                                        .padding(.leading, appState.sf(6))
                                }
                                CommitRow(commit: commit, compact: !rows.isEmpty)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: appState.sf(12)))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, appState.sf(40))
    }
}

// MARK: - CommitRow

/// One commit: message, short hash, author, and date — clicking opens its
/// full diff (`git show`) in `DiffViewerView`.
private struct CommitRow: View {
    @Environment(AppState.self) private var appState

    let commit: GitCommit
    /// Graph mode: fixed one-line rows so lanes line up with their commits.
    var compact = false

    @State private var isHovering = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(3)) {
            Text(commit.message)
                .font(.system(size: appState.sf(12), weight: .medium))
                .lineLimit(compact ? 1 : 2)
                .foregroundStyle(.primary)

            HStack(spacing: appState.sf(6)) {
                Text(commit.shortHash)
                    .font(.system(size: appState.sf(10), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, appState.sf(4))
                    .padding(.vertical, appState.sf(1))
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(appState.sf(3))

                Text(commit.author)
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: appState.sf(8))

                Text(Self.dateFormatter.string(from: commit.date))
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(6))
        .frame(maxWidth: .infinity, minHeight: compact ? appState.sf(44) : nil,
               maxHeight: compact ? appState.sf(44) : nil, alignment: .leading)
        .background(isHovering ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            Task { await appState.openDiffViewer(forCommit: commit) }
        }
        .help("View diff")
        .contextMenu {
            Button("Cherry-pick This Commit") { Task { await appState.cherryPick(commit) } }
            Button("Tag This Commit…") { Task { await appState.showTagSheet(target: commit.hash) } }
            Divider()
            Button("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }
        }
    }
}
