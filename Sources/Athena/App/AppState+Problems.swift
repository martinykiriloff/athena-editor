// AppState+Problems.swift
// Athena — navigating diagnostics: Problems panel clicks and F8 / ⇧F8.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    // MARK: - Navigation

    /// Opens the diagnostic's file and puts the caret on its line/column.
    /// Both are 1-based, the same as `DefinitionLocation`.
    func navigateToDiagnostic(_ diagnostic: Diagnostic) async {
        await navigateTo(DefinitionLocation(
            fileURL: diagnostic.fileURL,
            line: diagnostic.line,
            character: diagnostic.column
        ))
    }

    /// F8 / ⇧F8: moves to the next (or previous) diagnostic after the caret
    /// across every file, wrapping at the ends, as VS Code does.
    func goToAdjacentProblem(forward: Bool) async {
        let tab = focusedTab
        guard let target = Self.adjacentDiagnostic(
            in: sortedDiagnostics,
            fileURL: tab?.fileURL,
            line: tab?.cursorLine ?? 1,
            column: tab?.cursorColumn ?? 1,
            forward: forward
        ) else {
            statusMessage = "No problems"
            return
        }
        await navigateToDiagnostic(target)
        statusMessage = target.message
    }

    // MARK: - Ordering

    /// Every diagnostic ordered by file path, then line and column — the
    /// order the Problems panel lists them in and F8 walks.
    var sortedDiagnostics: [Diagnostic] {
        diagnostics.values.joined().sorted(by: Self.problemOrder)
    }

    nonisolated static func problemOrder(_ a: Diagnostic, _ b: Diagnostic) -> Bool {
        (a.fileURL.path, a.line, a.column) < (b.fileURL.path, b.line, b.column)
    }

    /// The first diagnostic strictly after (or, backward, strictly before)
    /// the given position in `sorted`, wrapping around. With no file open it
    /// starts from the top (or bottom). Pure, for tests.
    nonisolated static func adjacentDiagnostic(
        in sorted: [Diagnostic],
        fileURL: URL?,
        line: Int,
        column: Int,
        forward: Bool
    ) -> Diagnostic? {
        guard !sorted.isEmpty else { return nil }
        guard let path = fileURL?.path else {
            return forward ? sorted.first : sorted.last
        }
        let here = (path, line, column)
        if forward {
            return sorted.first { ($0.fileURL.path, $0.line, $0.column) > here } ?? sorted.first
        } else {
            return sorted.last { ($0.fileURL.path, $0.line, $0.column) < here } ?? sorted.last
        }
    }
}
