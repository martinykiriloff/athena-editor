// LocalHistoryView.swift
// Athena — overlay listing a file's Local History snapshots with diff and Restore.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - LocalHistoryView

struct LocalHistoryView: View {
    @Environment(AppState.self) private var appState

    private var state: LocalHistoryState { appState.localHistory }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { appState.closeLocalHistory() }

            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    snapshotList
                        .frame(width: appState.sf(220))
                    Divider()
                    diffPane
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: appState.sf(10)))
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
            .frame(width: appState.sf(980), height: appState.sf(640))
            .padding(.top, appState.sf(36))
        }
        .onKeyPress(.escape) { appState.closeLocalHistory(); return .handled }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: appState.sf(8)) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Local History — \(state.fileURL?.lastPathComponent ?? "")")
                    .font(.system(size: appState.sf(13), weight: .semibold))
                    .lineLimit(1)
                Text("Diff: selected snapshot → current editor content")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") {
                Task { await appState.restoreSelectedLocalHistorySnapshot() }
            }
            .disabled(state.selectedID == nil)
            Button {
                appState.closeLocalHistory()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, appState.sf(14))
        .frame(height: appState.sf(44))
    }

    // MARK: - Snapshot list

    @ViewBuilder
    private var snapshotList: some View {
        if state.snapshots.isEmpty {
            Text("No snapshots yet.\nSnapshots are taken each time the file is saved.")
                .multilineTextAlignment(.center)
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
                .padding(appState.sf(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.snapshots) { snapshot in
                        let selected = snapshot.id == state.selectedID
                        VStack(alignment: .leading, spacing: 0) {
                            Text(snapshot.date.formatted(date: .abbreviated, time: .standard))
                                .font(.system(size: appState.sf(12)))
                                .foregroundStyle(selected ? .white : .primary)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteCount), countStyle: .file))
                                .font(.system(size: appState.sf(11)))
                                .foregroundStyle(selected ? .white.opacity(0.7) : .secondary)
                        }
                        .padding(.horizontal, appState.sf(12))
                        .padding(.vertical, appState.sf(6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? Color.accentColor : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await appState.selectLocalHistorySnapshot(snapshot.id) } }
                    }
                }
            }
        }
    }

    // MARK: - Diff

    @ViewBuilder
    private var diffPane: some View {
        if let message = state.errorMessage {
            placeholder(message)
        } else if state.selectedID == nil {
            placeholder("Select a snapshot.")
        } else if state.diff.hunks.isEmpty {
            placeholder("Identical to current content.")
        } else {
            let highlighter = SyntaxHighlighter(
                language: state.fileURL.map { Language.detect(from: $0) } ?? .plaintext,
                theme: appState.currentTheme,
                fontSize: appState.sf(12),
                fontLigatures: false
            )
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: appState.sf(10)) {
                    ForEach(Array(state.diff.hunks.enumerated()), id: \.offset) { _, hunk in
                        DiffHunkView(hunk: hunk, highlighter: highlighter)
                    }
                }
                .padding(.vertical, appState.sf(8))
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
