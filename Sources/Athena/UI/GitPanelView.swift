// GitPanelView.swift
// Athena — full source control sidebar panel.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - GitPanelView

struct GitPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // 1. Header
            gitHeader

            Divider()

            // 2. Commit box
            commitSection

            Divider()

            // 3. Changes / empty state
            ScrollView {
                if appState.gitStatus.isClean {
                    emptyState
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
        .onAppear {
            Task { await appState.refreshGitStatus() }
        }
    }

    // MARK: - Header

    private var gitHeader: some View {
        HStack(spacing: 6) {
            Text("SOURCE CONTROL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            Spacer()

            // Commit-all shortcut (only when staged changes exist)
            if !appState.gitStatus.staged.isEmpty {
                Button {
                    guard let workspace = appState.workspace else { return }
                    Task {
                        try? await appState.gitService.commit(
                            message: appState.commitMessage,
                            at: workspace.rootURL
                        )
                        appState.commitMessage = ""
                        await appState.refreshGitStatus()
                    }
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Commit staged changes")
                .disabled(appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Refresh
            Button {
                Task { await appState.refreshGitStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 32)
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
                .font(.system(size: 12))
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
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

            // Commit button
            Button {
                guard let workspace = appState.workspace else { return }
                Task {
                    try? await appState.gitService.commit(
                        message: appState.commitMessage,
                        at: workspace.rootURL
                    )
                    appState.commitMessage = ""
                    await appState.refreshGitStatus()
                }
            } label: {
                Text("Commit")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || appState.gitStatus.staged.isEmpty
            )
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Change Sections

    private var changeSections: some View {
        VStack(spacing: 0) {
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
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No changes")
                .font(.system(size: 12))
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
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(appState.gitStatus.branch)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if appState.gitStatus.ahead > 0 {
                Label("\(appState.gitStatus.ahead)", systemImage: "arrow.up")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if appState.gitStatus.behind > 0 {
                Label("\(appState.gitStatus.behind)", systemImage: "arrow.down")
                    .font(.system(size: 10))
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("(\(changes.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }
}

// MARK: - GitFileRow

private struct GitFileRow: View {
    @Environment(AppState.self) private var appState

    let change: GitFileChange
    let isStaged: Bool

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // Status badge
            Text(change.status)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(statusColor(change.status))
                .cornerRadius(3)

            // Filename
            VStack(alignment: .leading, spacing: 0) {
                Text(fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !parentPath.isEmpty {
                    Text(parentPath)
                        .font(.system(size: 10))
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
                        .font(.system(size: 12))
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
        .contextMenu { contextMenuItems }
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
            Button("Open File") {
                let url = ws.rootURL.appendingPathComponent(change.path)
                Task { await appState.openFile(url) }
            }

            Divider()

            if !isStaged {
                Button("Discard Changes", role: .destructive) {
                    Task {
                        // Checkout the file to discard unstaged changes
                        _ = try? await appState.gitService.diff(
                            path: change.path,
                            staged: false,
                            at: ws.rootURL
                        )
                        await appState.refreshGitStatus()
                    }
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
}
