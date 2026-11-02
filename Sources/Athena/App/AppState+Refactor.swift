// AppState+Refactor.swift
// Athena — Safe Delete: delete the declaration at the caret, but find its
// references first and warn when it is still used.
// Swift 6, strict concurrency.

import Foundation
@preconcurrency import AppKit

// MARK: - Pure helpers

enum SafeDelete {

    /// The innermost document symbol whose line extent contains 1-based
    /// `line`; the deeper one wins a tie.
    static func target(in symbols: [DocumentSymbol], line: Int) -> DocumentSymbol? {
        var best: (symbol: DocumentSymbol, extent: Int, depth: Int)?
        for (symbol, depth) in flattenDocumentSymbols(symbols)
        where symbol.rangeStartLine <= line && line <= symbol.rangeEndLine {
            let extent = symbol.rangeEndLine - symbol.rangeStartLine
            if best == nil || extent < best!.extent || (extent == best!.extent && depth > best!.depth) {
                best = (symbol, extent, depth)
            }
        }
        return best?.symbol
    }

    /// References that survive the deletion: everything except the
    /// declaration's own lines (1-based, inclusive) in `file`.
    static func externalUsages(_ references: [DefinitionLocation], file: URL, deletedLines: ClosedRange<Int>) -> [DefinitionLocation] {
        references.filter { !($0.fileURL == file && deletedLines.contains($0.line)) }
    }

    /// An edit removing 1-based lines `lines` of `content` entirely.
    static func deletionEdit(lines: ClosedRange<Int>, in content: String) -> LSPTextEdit {
        let all = content.components(separatedBy: "\n")
        let first = lines.lowerBound - 1
        let last = min(lines.upperBound, all.count) - 1
        if last + 1 < all.count {
            return LSPTextEdit(startLine: first, startCharacter: 0, endLine: last + 1, endCharacter: 0, newText: "")
        }
        return LSPTextEdit(startLine: first, startCharacter: 0, endLine: last,
                           endCharacter: (all[last] as NSString).length, newText: "")
    }
}

@MainActor
extension AppState {

    // MARK: - Safe Delete

    /// Deletes the declaration containing the caret after checking its
    /// references. With none left it deletes straight away; otherwise the
    /// user chooses between showing the usages and deleting anyway. Needs a
    /// running language server: without one the usages can't be checked, and
    /// that is stated rather than treated as "unused".
    func safeDeleteAtCaret() async {
        guard let tab = focusedTab, let url = tab.fileURL else { return }
        guard await lspManager.hasServer(for: Language.detect(from: url)) else {
            statusMessage = "Safe Delete needs a language server for this file"
            return
        }
        guard let symbol = SafeDelete.target(in: documentSymbols, line: tab.cursorLine) else {
            statusMessage = "Safe Delete: put the caret inside a declaration"
            return
        }
        let lines = symbol.rangeStartLine...max(symbol.rangeStartLine, symbol.rangeEndLine)
        let references = (try? await lspManager.references(
            fileURL: url, line: symbol.line - 1, character: symbol.character - 1, includeDeclaration: false
        )) ?? []
        let usages = SafeDelete.externalUsages(references, file: url, deletedLines: lines)

        if !usages.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\"\(symbol.name)\" is used \(usages.count) time\(usages.count == 1 ? "" : "s")"
            alert.informativeText = "Deleting it will leave those references broken."
            alert.addButton(withTitle: "Show Usages")
            alert.addButton(withTitle: "Delete Anyway")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                await findReferences(fileURL: url, line: symbol.line - 1, character: symbol.character - 1)
                return
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }

        let edit = SafeDelete.deletionEdit(lines: lines, in: tab.content)
        if await applyWorkspaceEdit([url: [edit]]) {
            statusMessage = "Deleted \(symbol.name)"
        }
    }
}
