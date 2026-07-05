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
                        ForEach(appState.commitHistory) { commit in
                            CommitRow(commit: commit)
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear {
            Task { await appState.refreshCommitHistory() }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: appState.sf(12)))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 40)
    }
}

// MARK: - CommitRow

/// One commit: message, short hash, author, and date — clicking opens its
/// full diff (`git show`) in `DiffViewerView`.
private struct CommitRow: View {
    @Environment(AppState.self) private var appState

    let commit: GitCommit

    @State private var isHovering = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.message)
                .font(.system(size: appState.sf(12), weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .font(.system(size: appState.sf(10), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)

                Text(commit.author)
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(Self.dateFormatter.string(from: commit.date))
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            Task { await appState.openDiffViewer(forCommit: commit) }
        }
        .help("View diff")
    }
}
