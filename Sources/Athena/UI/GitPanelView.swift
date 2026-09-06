// GitPanelView.swift
// Athena — full source control sidebar panel.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - GitPanelView

struct GitPanelView: View {
    @Environment(AppState.self) private var appState

    /// Toggles the panel between the Changes view (default) and
    /// `CommitHistoryView` — the smallest clean integration of the commit
    /// history browser into the existing Source Control panel (plan.md item
    /// 20 point 2) rather than a new top-level sidebar panel. Backed by
    /// `AppState.gitPanelShowsHistory` so "File History" on a row can flip it.
    private var showHistory: Bool { appState.gitPanelShowsHistory }

    var body: some View {
        VStack(spacing: 0) {
            // 1. Header
            gitHeader

            Divider()

            if showHistory {
                // History view
                CommitHistoryView()
            } else {
                // 2. Commit box
                commitSection

                Divider()

                // 3. Changes / empty state
                ScrollView {
                    if appState.gitStatus.isClean {
                        emptyState
                        if !appState.gitStashes.isEmpty {
                            StashSection(stashes: appState.gitStashes)
                                .padding(.vertical, 4)
                        }
                    } else {
                        changeSections
                    }
                }

                // 4. Ahead / behind row
                if let workspace = appState.workspace,
                   !appState.gitStatus.branch.isEmpty
                {
                    Divider()
                    aheadBehindBar(workspace: workspace)
                }
            }
        }
        .onAppear {
            Task { await appState.refreshGitStatus() }
        }
    }

    // MARK: - Header

    private var gitHeader: some View {
        HStack(spacing: 6) {
            Text(showHistory ? "HISTORY" : "SOURCE CONTROL")
                .font(.system(size: appState.sf(11), weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            Spacer()

            // Commit-all shortcut (only when staged changes exist, Changes view only)
            if !showHistory, !appState.gitStatus.staged.isEmpty {
                Button {
                    Task { await appState.commitStaged() }
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: appState.sf(13)))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Commit staged changes")
                .disabled(appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Fetch / Pull / Push — the remote half of source control.
            if !showHistory, !appState.gitStatus.branch.isEmpty {
                if appState.isGitSyncing {
                    ProgressView().controlSize(.mini)
                } else {
                    headerButton("arrow.triangle.2.circlepath", help: "Fetch") {
                        Task { await appState.gitFetch() }
                    }
                    headerButton("arrow.down.circle", help: appState.gitStatus.behind > 0
                                 ? "Pull (\(appState.gitStatus.behind) behind)" : "Pull") {
                        Task { await appState.gitPull() }
                    }
                    headerButton("arrow.up.circle", help: appState.gitStatus.ahead > 0
                                 ? "Push (\(appState.gitStatus.ahead) ahead)" : "Push") {
                        Task { await appState.gitPush() }
                    }
                }
            }

            // History / Changes toggle
            Button {
                appState.gitPanelShowsHistory.toggle()
                if appState.gitPanelShowsHistory {
                    Task { await appState.refreshCommitHistory() }
                }
            } label: {
                Image(systemName: showHistory ? "arrow.uturn.left" : "clock.arrow.circlepath")
                    .font(.system(size: appState.sf(12)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(showHistory ? "Back to Changes" : "Commit History")

            // Refresh
            Button {
                Task {
                    if showHistory {
                        await appState.refreshCommitHistory()
                    } else {
                        await appState.refreshGitStatus()
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: appState.sf(12)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 32)
    }

    private func headerButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Commit Section

    private var commitSection: some View {
        VStack(spacing: 6) {
            // TextEditor with placeholder overlay
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { appState.commitMessage },
                    set: { appState.commitMessage = $0 }
                ))
                .font(.system(size: appState.sf(12)))
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

                // Placeholder
                if appState.commitMessage.isEmpty {
                    Text("Message (Cmd+Return to commit)")
                        .font(.system(size: appState.sf(12)))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 6) {
                // Commit button
                Button {
                    Task { await appState.commitStaged() }
                } label: {
                    Text("Commit")
                        .font(.system(size: appState.sf(12), weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || appState.gitStatus.staged.isEmpty
                )
                .keyboardShortcut(.return, modifiers: .command)

                // Stash — the message box doubles as the stash message.
                Menu {
                    Button("Stash Changes") {
                        Task { await appState.stashChanges(includeUntracked: false) }
                    }
                    Button("Stash Including Untracked") {
                        Task { await appState.stashChanges(includeUntracked: true) }
                    }
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: appState.sf(12)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .help("Stash working-tree changes")
                .disabled(appState.gitStatus.isClean)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Change Sections

    private var changeSections: some View {
        VStack(spacing: 0) {
            // Shown first — an unresolved conflict is the most urgent thing
            // in the working tree, matching VS Code's own "Merge Changes"
            // section ordering (plan.md item 23, "D5").
            if !appState.gitStatus.conflicted.isEmpty {
                ChangeSection(
                    title: "Merge Conflicts",
                    changes: appState.gitStatus.conflicted,
                    isStaged: false
                )
            }

            if !appState.gitStatus.staged.isEmpty {
                ChangeSection(
                    title: "Staged Changes",
                    changes: appState.gitStatus.staged,
                    isStaged: true
                )
            }

            if !appState.gitStatus.unstaged.isEmpty {
                ChangeSection(
                    title: "Changes",
                    changes: appState.gitStatus.unstaged,
                    isStaged: false
                )
            }

            if !appState.gitStatus.untracked.isEmpty {
                ChangeSection(
                    title: "Untracked Files",
                    changes: appState.gitStatus.untracked,
                    isStaged: false
                )
            }

            if !appState.gitStashes.isEmpty {
                StashSection(stashes: appState.gitStashes)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: appState.sf(28)))
                .foregroundStyle(.tertiary)
            Text("No changes")
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Ahead / Behind Bar

    @ViewBuilder
    private func aheadBehindBar(workspace: WorkspaceModel) -> some View {
        HStack(spacing: 8) {
            // Branch name
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(.secondary)
            Text(appState.gitStatus.branch)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if appState.gitStatus.ahead > 0 {
                Label("\(appState.gitStatus.ahead)", systemImage: "arrow.up")
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.secondary)
            }
            if appState.gitStatus.behind > 0 {
                Label("\(appState.gitStatus.behind)", systemImage: "arrow.down")
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 26)
    }
}

// MARK: - ChangeSection

private struct ChangeSection: View {
    @Environment(AppState.self) private var appState

    let title: String
    let changes: [GitFileChange]
    let isStaged: Bool

    @State private var isExpanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(changes) { change in
                GitFileRow(change: change, isStaged: isStaged)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: appState.sf(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("(\(changes.count))")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }
}

// MARK: - StashSection

private struct StashSection: View {
    @Environment(AppState.self) private var appState
    let stashes: [GitStash]
    @State private var isExpanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(stashes) { stash in
                StashRow(stash: stash)
            }
        } label: {
            HStack(spacing: 4) {
                Text("Stashes")
                    .font(.system(size: appState.sf(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("(\(stashes.count))")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }
}

private struct StashRow: View {
    @Environment(AppState.self) private var appState
    let stash: GitStash
    @State private var isHovering = false
    @State private var showDropConfirmation = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .font(.system(size: appState.sf(10)))
                .foregroundStyle(.secondary)
            Text(stash.message)
                .font(.system(size: appState.sf(12)))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if isHovering {
                Button {
                    Task { await appState.applyStash(stash, pop: true) }
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: appState.sf(12)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Pop (apply and remove)")
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Apply") { Task { await appState.applyStash(stash, pop: false) } }
            Button("Pop")   { Task { await appState.applyStash(stash, pop: true) } }
            Divider()
            Button("Drop", role: .destructive) { showDropConfirmation = true }
        }
        .alert("Drop stash \"\(stash.message)\"?", isPresented: $showDropConfirmation) {
            Button("Drop", role: .destructive) { Task { await appState.dropStash(stash) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stashed changes will be lost.")
        }
    }
}

// MARK: - GitFileRow

private struct GitFileRow: View {
    @Environment(AppState.self) private var appState

    let change: GitFileChange
    let isStaged: Bool

    @State private var isHovering: Bool = false
    @State private var showDiscardConfirmation: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // Status badge
            Text(change.status)
                .font(.system(size: appState.sf(10), weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(statusColor(change.status))
                .cornerRadius(3)

            // Filename
            VStack(alignment: .leading, spacing: 0) {
                Text(fileName)
                    .font(.system(size: appState.sf(12)))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !parentPath.isEmpty {
                    Text(parentPath)
                        .font(.system(size: appState.sf(10)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 0)

            // Stage / unstage button
            if isHovering {
                Button {
                    guard let ws = appState.workspace else { return }
                    Task {
                        if isStaged {
                            try? await appState.gitService.unstage([change.path], at: ws.rootURL)
                        } else {
                            try? await appState.gitService.stage([change.path], at: ws.rootURL)
                        }
                        await appState.refreshGitStatus()
                    }
                } label: {
                    Image(systemName: isStaged ? "minus.circle" : "plus.circle")
                        .font(.system(size: appState.sf(12)))
                        .foregroundStyle(isStaged ? .red : .green)
                }
                .buttonStyle(.plain)
                .help(isStaged ? "Unstage" : "Stage")
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            Task { await appState.openDiffViewer(for: change, staged: isStaged) }
        }
        .contextMenu { contextMenuItems }
        .alert("Discard changes to \"\(fileName)\"?", isPresented: $showDiscardConfirmation) {
            Button("Discard Changes", role: .destructive) {
                Task { await discardChanges() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: Helpers

    private var fileName: String {
        URL(fileURLWithPath: change.path).lastPathComponent
    }

    private var parentPath: String {
        let url = URL(fileURLWithPath: change.path)
        let parent = url.deletingLastPathComponent().path
        return parent == "." ? "" : parent
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "A":  return .green
        case "M":  return .orange
        case "D":  return .red
        case "R":  return .blue
        case "C":  return .purple
        case "?":  return .gray
        default:   return .gray
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let ws = appState.workspace {
            Button("View Diff") {
                Task { await appState.openDiffViewer(for: change, staged: isStaged) }
            }

            Button("Open File") {
                let url = ws.rootURL.appendingPathComponent(change.path)
                Task { await appState.openFile(url) }
            }

            Button("File History") {
                Task { await appState.showFileHistory(path: change.path) }
            }

            Divider()

            if !isStaged {
                Button("Discard Changes", role: .destructive) {
                    showDiscardConfirmation = true
                }
            }

            Button(isStaged ? "Unstage" : "Stage") {
                Task {
                    if isStaged {
                        try? await appState.gitService.unstage([change.path], at: ws.rootURL)
                    } else {
                        try? await appState.gitService.stage([change.path], at: ws.rootURL)
                    }
                    await appState.refreshGitStatus()
                }
            }
        }
    }

    /// Reverts the file's unstaged working-tree changes back to HEAD/index and
    /// refreshes Git status; see `AppState.discardChanges(path:)`.
    private func discardChanges() async {
        await appState.discardChanges(path: change.path)
    }
}
