// AppState+GitAdvanced.swift
// Athena — amend, cherry-pick, tags, merge/rebase, merge editor, hunk actions,
// graph, line history and pull-request status flows for Source Control.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    // MARK: - Operation plumbing

    /// Runs `operation`, reports failure in the status bar, then refreshes
    /// status (which also re-detects a paused merge/rebase/cherry-pick) and
    /// history. A conflict is not reported as a bare failure: the banner
    /// takes over, so the message just says to resolve.
    @discardableResult
    func runGitOperation(_ verb: String, _ operation: (GitService, URL) async throws -> Void) async -> Bool {
        guard let workspace else { return false }
        var succeeded = true
        do {
            try await operation(gitService, workspace.rootURL)
            statusMessage = "\(verb) done"
        } catch {
            succeeded = false
            let detail = error.localizedDescription
            statusMessage = detail.contains("CONFLICT") || detail.localizedCaseInsensitiveContains("conflict")
                ? "\(verb): conflicts — resolve them, then continue or abort"
                : "\(verb) failed: \(detail)"
        }
        await refreshGitStatus()
        if gitPanelShowsHistory { await refreshCommitHistory() }
        return succeeded
    }

    func refreshGitOperation() async {
        guard let workspace else { gitExtras.operation = nil; return }
        gitExtras.operation = await gitService.currentOperation(at: workspace.rootURL)
    }

    // MARK: - Amend / cherry-pick / merge / rebase

    /// Amends HEAD with the staged changes; the commit box text (if any)
    /// replaces the message, otherwise the old message is kept.
    func amendLastCommit() async {
        let message = commitMessage
        if await runGitOperation("Amend", { try await $0.amend(message: message, at: $1) }) {
            commitMessage = ""
        }
    }

    func cherryPick(_ commit: GitCommit) async {
        await runGitOperation("Cherry-pick \(commit.shortHash)") { try await $0.cherryPick(commit.hash, at: $1) }
    }

    func mergeBranch(_ name: String) async {
        await runGitOperation("Merge \(name)") { try await $0.merge(name, at: $1) }
    }

    /// Non-interactive rebase of the current branch onto `name`.
    func rebaseOnto(_ name: String) async {
        await runGitOperation("Rebase onto \(name)") { try await $0.rebase(onto: name, at: $1) }
    }

    /// Aborts whichever operation is paused.
    func abortGitOperation() async {
        guard let operation = gitExtras.operation else { return }
        await runGitOperation("Abort \(operation.title.lowercased())") { service, url in
            switch operation {
            case .merge:      try await service.mergeAbort(at: url)
            case .rebase:     try await service.rebaseAbort(at: url)
            case .cherryPick: try await service.cherryPickAbort(at: url)
            }
        }
        await reloadConflictedTabs()
    }

    /// Continues the paused operation once conflicts are resolved and
    /// staged. A merge is finished with a plain commit.
    func continueGitOperation() async {
        guard let operation = gitExtras.operation else { return }
        await runGitOperation("Continue \(operation.title.lowercased())") { service, url in
            switch operation {
            case .merge:      try await service.mergeContinue(at: url)
            case .rebase:     try await service.rebaseContinue(at: url)
            case .cherryPick: try await service.cherryPickContinue(at: url)
            }
        }
    }

    /// Rereads every open tab from disk after an abort rewrote files.
    private func reloadConflictedTabs() async {
        for tab in openTabs {
            guard let url = tab.fileURL, !tab.isDirty,
                  let content = try? await fileService.readFile(url), content != tab.content else { continue }
            updateTabs(withFileURL: url) { $0.content = content; $0.externallyModified = false }
        }
    }

    // MARK: - Tags

    func refreshTags() async {
        guard let workspace else { return }
        gitExtras.tags = (try? await gitService.tags(at: workspace.rootURL)) ?? []
    }

    func createTag(name: String, target: String?, message: String?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runGitOperation("Tag \(trimmed)") { try await $0.createTag(trimmed, at: target, message: message, in: $1) }
        await refreshTags()
    }

    func deleteTag(_ tag: GitTag) async {
        await runGitOperation("Delete tag \(tag.name)") { try await $0.deleteTag(tag.name, at: $1) }
        await refreshTags()
    }

    func showTagSheet(target: String? = nil) async {
        gitExtras.tagTarget = target
        gitExtras.showTags = true
        await refreshTags()
    }

    // MARK: - Merge editor

    /// The conflicted file's current on-disk text (markers included).
    func mergeEditorText(for path: String) async -> String? {
        guard let workspace else { return nil }
        return try? await fileService.readFile(workspace.rootURL.appendingPathComponent(path))
    }

    /// Writes the resolved text, stages the file, and refreshes any open tab.
    func saveMergeResolution(path: String, text: String) async {
        guard let workspace else { return }
        let url = workspace.rootURL.appendingPathComponent(path)
        do {
            try await fileService.writeFile(url, content: text)
            try await gitService.stage([path], at: workspace.rootURL)
            statusMessage = "Resolved \(path)"
        } catch {
            statusMessage = "Couldn't save resolution: \(error.localizedDescription)"
            return
        }
        updateTabs(withFileURL: url) { tab in
            tab.content = text
            tab.isDirty = false
            tab.externallyModified = false
        }
        await refreshGitStatus()
    }

    // MARK: - Hunks (editor gutter)

    /// Stages / unstages / reverts the hunk under the working-tree `line` of
    /// `fileURL`, then refreshes status, the change bars, and (for a revert)
    /// the open buffer.
    func applyGitHunk(_ action: GitHunkAction, fileURL: URL, line: Int) async {
        guard let workspace else { return }
        let root = workspace.rootURL.standardizedFileURL.path + "/"
        let full = fileURL.standardizedFileURL.path
        guard full.hasPrefix(root) else { return }
        let relative = String(full.dropFirst(root.count))

        // A revert rewrites the file: refuse when the buffer has unsaved
        // edits, since the hunk was computed from the on-disk text.
        if let tab = openTabs.first(where: { $0.fileURL == fileURL }), tab.isDirty {
            statusMessage = "Save the file before staging or reverting a hunk"
            return
        }
        do {
            try await gitService.applyHunk(action, path: relative, line: line, at: workspace.rootURL)
        } catch {
            statusMessage = "Hunk action failed: \(error.localizedDescription)"
            return
        }
        statusMessage = switch action {
        case .stage:   "Staged hunk"
        case .unstage: "Unstaged hunk"
        case .revert:  "Reverted hunk"
        }
        await refreshGitStatus()
        if action == .revert, let content = try? await fileService.readFile(fileURL) {
            updateTabs(withFileURL: fileURL) { tab in
                tab.content = content
                tab.isDirty = false
                tab.externallyModified = false
            }
        }
        for tab in openTabs where tab.fileURL == fileURL { await refreshGitLineChanges(for: tab) }
    }

    // MARK: - History: graph, file, line

    func setGraphMode(_ on: Bool) async {
        gitExtras.showGraph = on
        if on { commitHistoryPath = nil; gitExtras.lineHistoryLabel = nil }
        await refreshCommitHistory()
    }

    /// History of the line the cursor is on in the focused tab (`git log -L`).
    func showLineHistoryForCursor() async {
        guard let workspace, let tab = focusedTab, let url = tab.fileURL else { return }
        let root = workspace.rootURL.standardizedFileURL.path + "/"
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(root) else { return }
        let relative = String(full.dropFirst(root.count))
        let line = tab.cursorLine
        gitExtras.showGraph = false
        gitExtras.graphRows = []
        isLoadingCommitHistory = true
        commitHistoryErrorMessage = nil
        gitPanelShowsHistory = true
        defer { isLoadingCommitHistory = false }
        do {
            commitHistory = try await gitService.lineHistory(path: relative, start: line, end: line, limit: 50, at: workspace.rootURL)
            commitHistoryPath = nil
            gitExtras.lineHistoryLabel = "\(relative):\(line)"
        } catch {
            commitHistoryErrorMessage = "Git error: \(error.localizedDescription)"
        }
    }

    func clearLineHistory() async {
        gitExtras.lineHistoryLabel = nil
        await refreshCommitHistory()
    }

    // MARK: - Pull request + CI (gh)

    /// Looks for `gh`; the PR entry points stay hidden while this is nil.
    func detectGitHubCLI() async {
        gitExtras.ghPath = await toolCheckService.ghPath()
    }

    func refreshPullRequest() async {
        guard let workspace else { return }
        if gitExtras.ghPath == nil { await detectGitHubCLI() }
        guard let gh = gitExtras.ghPath else { return }
        gitExtras.isLoadingPullRequest = true
        defer { gitExtras.isLoadingPullRequest = false }
        gitExtras.pullRequestMessage = nil
        do {
            let pr = try await githubService.pullRequest(gh: gh, at: workspace.rootURL)
            gitExtras.pullRequest = pr
            gitExtras.checks = pr == nil ? [] : ((try? await githubService.checks(gh: gh, at: workspace.rootURL)) ?? [])
            if pr == nil { gitExtras.pullRequestMessage = "No open pull request for this branch." }
        } catch {
            gitExtras.pullRequest = nil
            gitExtras.checks = []
            gitExtras.pullRequestMessage = error.localizedDescription
        }
    }
}
