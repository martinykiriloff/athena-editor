// AppState+ToolChecks.swift
// Athena — first-run checks for git, the claude CLI and language servers.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    // MARK: - Checks

    /// Launch checks for the tools whole panels depend on.
    func runToolChecks() async {
        if let notice = await toolCheckService.gitNotice() { showToolNotice(notice) }
        if let notice = await toolCheckService.claudeNotice(binaryName: activeClaudeAccount.binaryName) {
            showToolNotice(notice)
        }
    }

    /// Called when a file opens: says so if its language has a known server
    /// that isn't installed, instead of completions silently never coming.
    func checkLanguageServer(for language: Language) async {
        guard let notice = ToolCheckService.languageServerNotice(for: language),
              !toolNotices.contains(where: { $0.id == notice.id }),
              !(await lspManager.hasServer(for: language))
        else { return }
        showToolNotice(notice)
    }

    // MARK: - Notices

    nonisolated static let dismissedToolNoticesKey = "athenaDismissedToolNotices"

    func showToolNotice(_ notice: ToolNotice) {
        let dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedToolNoticesKey) ?? []
        guard !dismissed.contains(notice.id), !toolNotices.contains(where: { $0.id == notice.id }) else { return }
        toolNotices.append(notice)
    }

    /// Hides the notice and doesn't show it again on later launches.
    func dismissToolNotice(_ id: String) {
        toolNotices.removeAll { $0.id == id }
        var dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedToolNoticesKey) ?? []
        if !dismissed.contains(id) { dismissed.append(id) }
        UserDefaults.standard.set(dismissed, forKey: Self.dismissedToolNoticesKey)
    }
}
