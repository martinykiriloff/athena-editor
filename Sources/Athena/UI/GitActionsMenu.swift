// GitActionsMenu.swift
// Athena — "more actions" menu in the Source Control header: amend, merge,
// rebase, tags, pull request status.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - GitActionsMenu

struct GitActionsMenu: View {
    @Environment(AppState.self) private var appState

    private var localBranches: [GitBranch] {
        appState.branches.filter { !$0.isRemote && !$0.isCurrent }
    }

    var body: some View {
        Menu {
            Button("Amend Last Commit") { Task { await appState.amendLastCommit() } }
                .help("Adds staged changes to HEAD; the commit message box (if filled) replaces the message")
            Divider()
            Menu("Merge Branch Into Current") {
                ForEach(localBranches) { b in
                    Button(b.name) { Task { await appState.mergeBranch(b.name) } }
                }
            }
            .disabled(localBranches.isEmpty || appState.gitExtras.operation != nil)
            Menu("Rebase Current Onto") {
                ForEach(localBranches) { b in
                    Button(b.name) { Task { await appState.rebaseOnto(b.name) } }
                }
            }
            .disabled(localBranches.isEmpty || appState.gitExtras.operation != nil)
            if let operation = appState.gitExtras.operation {
                Divider()
                Button("Continue \(operation.title)") { Task { await appState.continueGitOperation() } }
                Button("Abort \(operation.title)") { Task { await appState.abortGitOperation() } }
            }
            Divider()
            Button("Tags…") { Task { await appState.showTagSheet() } }
            if appState.gitExtras.ghPath != nil {
                Button("Pull Request & CI Status…") { appState.gitExtras.showPullRequests = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Git actions")
        .task { await appState.detectGitHubCLI() }
    }
}
