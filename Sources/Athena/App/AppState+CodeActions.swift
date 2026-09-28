// AppState+CodeActions.swift
// Athena — Quick Fix (⌘.): LSP code actions and applying workspace edits.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    // MARK: - Requesting

    /// Code actions for the 1-based selection `start`…`end` in `fileURL`.
    func codeActions(
        fileURL: URL,
        start: (line: Int, column: Int),
        end: (line: Int, column: Int)
    ) async -> [CodeAction] {
        (try? await lspManager.codeActions(
            fileURL: fileURL,
            startLine: start.line - 1, startCharacter: start.column - 1,
            endLine: end.line - 1, endCharacter: end.column - 1
        )) ?? []
    }

    // MARK: - Applying

    /// Runs `action`: applies its edit, then its command (whose own edits
    /// arrive through `workspace/applyEdit`). `skipping` names a file whose
    /// edits the caller already applied through its text view.
    func performCodeAction(_ action: CodeAction, skipping handledURL: URL? = nil) async {
        var edits = action.edits
        if let handledURL { edits.removeValue(forKey: handledURL) }
        if !edits.isEmpty {
            _ = await applyWorkspaceEdit(edits)
        }
        if let command = action.command {
            await lspManager.executeCommand(command, language: action.language)
        }
        statusMessage = action.title
    }

    /// Applies per-file LSP edits. A file open in a tab is edited in the
    /// buffer and left unsaved, as VS Code does; any other file is edited on
    /// disk. Returns false if a file could not be read or written.
    func applyWorkspaceEdit(_ edits: [URL: [LSPTextEdit]]) async -> Bool {
        var allApplied = true
        var wroteToDisk = false

        for (url, textEdits) in edits where !textEdits.isEmpty {
            let matching = [EditorGroupSide.primary, .secondary]
                .flatMap { tabs(in: $0) }
                .filter { $0.fileURL == url }
            if let first = matching.first {
                let updated = applyLSPTextEdits(textEdits, to: first.content)
                // Every tab on the file gets the same text; `updateTabContent`
                // marks it dirty and tells the language server.
                for tab in matching { updateTabContent(tab.id, content: updated) }
            } else {
                do {
                    let original = try await fileService.readFile(url)
                    try await fileService.writeFile(url, content: applyLSPTextEdits(textEdits, to: original))
                    wroteToDisk = true
                } catch {
                    allApplied = false
                    statusMessage = "Couldn't apply edit to \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }

        if wroteToDisk { await refreshGitStatus() }
        return allApplied
    }
}
