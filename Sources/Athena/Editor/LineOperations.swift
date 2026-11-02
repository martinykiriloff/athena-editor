// LineOperations.swift
// Athena — pure, NSTextView-independent line manipulation (move/copy/delete).
// Swift 6, strict concurrency.

import Foundation

// MARK: - LineOperations

/// Computes the minimal text edit for each VS Code-parity line command
/// (plan.md item 17, "B7"), independent of `NSTextView` so the core logic is
/// unit-testable. Every function takes the full document `text` and the
/// caret/selection (`NSRange`, UTF-16 offsets, matching every other range
/// convention in this codebase) and returns an `Edit` describing exactly
/// what to replace and where the selection should land afterward — callers
/// apply it through the same `shouldChangeText`/`replaceCharacters`/
/// `didChangeText` undo-aware path already used for indent/comment
/// (`EditorView.Coordinator.replace(_:with:in:)`).
///
/// "Current line(s)" is always `(text as NSString).lineRange(for: selection)`
/// — the same primitive `toggleComment`/`shiftIndent` already use — so a
/// multi-line selection operates on every touched line, not just the line
/// the caret happens to sit on.
enum LineOperations {

    /// A minimal, undo-friendly text replacement plus the selection to apply
    /// after it lands.
    struct Edit: Sendable, Equatable {
        let range: NSRange
        let replacement: String
        let newSelection: NSRange
    }

    // MARK: - Move Line Up / Down (⌥↑ / ⌥↓)

    /// Swaps the current line(s) with the line immediately above. Returns
    /// `nil` (no-op) when the touched block already starts at the top of
    /// the document.
    static func moveUp(text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        let block = ns.lineRange(for: selection)
        guard block.location > 0 else { return nil }

        let prev = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
        let combined = NSRange(location: prev.location, length: NSMaxRange(block) - prev.location)

        let prevText  = ns.substring(with: prev)   // never the last line: always "\n"-terminated
        let blockText = ns.substring(with: block)

        let blockHasTerminator = blockText.hasSuffix("\n")
        let blockContent = blockHasTerminator ? String(blockText.dropLast()) : blockText
        let prevContent  = String(prevText.dropLast())

        let replacement = blockContent + "\n" + prevContent + (blockHasTerminator ? "\n" : "")
        // The moved block's start doesn't change; everything in it shifts up
        // by exactly the previous line's length (the line that now follows it).
        let newSelection = NSRange(location: selection.location - prev.length, length: selection.length)
        return Edit(range: combined, replacement: replacement, newSelection: newSelection)
    }

    /// Swaps the current line(s) with the line immediately below. Returns
    /// `nil` (no-op) when the touched block already reaches the end of the
    /// document.
    static func moveDown(text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        let block = ns.lineRange(for: selection)
        guard NSMaxRange(block) < ns.length else { return nil }

        let next = ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        let combined = NSRange(location: block.location, length: NSMaxRange(next) - block.location)

        let blockText = ns.substring(with: block)   // a next line follows: always "\n"-terminated
        let nextText  = ns.substring(with: next)

        let nextHasTerminator = nextText.hasSuffix("\n")
        let nextContent  = nextHasTerminator ? String(nextText.dropLast()) : nextText
        let blockContent = String(blockText.dropLast())

        let replacement = nextContent + "\n" + blockContent + (nextHasTerminator ? "\n" : "")
        let shift = nextContent.utf16.count + 1
        let newSelection = NSRange(location: selection.location + shift, length: selection.length)
        return Edit(range: combined, replacement: replacement, newSelection: newSelection)
    }

    // MARK: - Copy Line Up / Down (⌥⇧↑ / ⌥⇧↓)

    /// Duplicates the current line(s), inserting the copy immediately
    /// above. Matches VS Code: the cursor/selection stays on the ORIGINAL
    /// content, which is now pushed down below the new copy — pressing
    /// Copy Line Up repeatedly stacks duplicates upward while the caret
    /// trails at the bottom of the stack.
    static func copyUp(text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let block = ns.lineRange(for: selection)
        let blockText = ns.substring(with: block)
        let hasTerminator = blockText.hasSuffix("\n")
        // The copy always needs its own terminator, even when the original
        // (the last line) doesn't have one — it's no longer last afterward.
        let insertion = hasTerminator ? blockText : blockText + "\n"
        let insertionPoint = NSRange(location: block.location, length: 0)
        let newSelection = NSRange(
            location: selection.location + (insertion as NSString).length,
            length: selection.length
        )
        return Edit(range: insertionPoint, replacement: insertion, newSelection: newSelection)
    }

    /// Duplicates the current line(s), inserting the copy immediately
    /// below. Matches VS Code: the cursor/selection moves to the NEW copy —
    /// pressing Copy Line Down repeatedly stacks duplicates downward while
    /// the caret leads at the newest copy.
    static func copyDown(text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let block = ns.lineRange(for: selection)
        let blockText = ns.substring(with: block)
        let hasTerminator = blockText.hasSuffix("\n")
        // The original keeps its terminator-less status if it had none; the
        // separator moves in front of the copy instead.
        let insertion = hasTerminator ? blockText : "\n" + blockText
        let insertionPoint = NSRange(location: NSMaxRange(block), length: 0)
        let shift = (insertion as NSString).length
        let newSelection = NSRange(location: selection.location + shift, length: selection.length)
        return Edit(range: insertionPoint, replacement: insertion, newSelection: newSelection)
    }

    // MARK: - Delete Line (⌘⇧K)

    /// Deletes every line touched by `selection`, terminator included. The
    /// selection collapses to a caret at the deleted block's old start
    /// offset, which — after the deletion closes the gap — is exactly the
    /// start of the line that followed (or end of document, if the deleted
    /// block was the last line).
    static func deleteLines(text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let block = ns.lineRange(for: selection)
        return Edit(range: block, replacement: "", newSelection: NSRange(location: block.location, length: 0))
    }

    // MARK: - Line block helpers

    /// The whole lines a command applies to. VS Code excludes a final line the
    /// selection only touches at column 0, so selecting "a\nb\n" up to the start
    /// of the next line does not drag that line in.
    private struct Block {
        let range: NSRange          // full lines, last terminator included
        let lines: [String]         // contents, no "\n"
        let endsWithNewline: Bool
    }

    private static func block(text: String, selection: NSRange, wholeDocumentIfEmpty: Bool = false) -> Block {
        let ns = text as NSString
        var sel = selection
        if wholeDocumentIfEmpty, selection.length == 0 {
            sel = NSRange(location: 0, length: ns.length)
        } else if sel.length > 0, ns.character(at: NSMaxRange(sel) - 1) == 0x0A {
            sel.length -= 1
        }
        let range = ns.lineRange(for: sel)
        var content = ns.substring(with: range)
        let nl = content.hasSuffix("\n")
        if nl { content.removeLast() }
        return Block(range: range, lines: content.components(separatedBy: "\n"), endsWithNewline: nl)
    }

    private static func edit(_ b: Block, lines: [String]) -> Edit {
        let body = lines.joined(separator: "\n")
        let replacement = body + (b.endsWithNewline ? "\n" : "")
        return Edit(range: b.range, replacement: replacement,
                    newSelection: NSRange(location: b.range.location, length: (body as NSString).length))
    }

    /// Sort/reverse need at least two lines. With an empty selection they act
    /// on the whole document (deliberately unlike VS Code, whose sort ignores
    /// a bare caret).
    private static func multiLineBlock(text: String, selection: NSRange) -> Block? {
        let b = block(text: text, selection: selection, wholeDocumentIfEmpty: true)
        return b.lines.count >= 2 ? b : nil
    }

    // MARK: - Sort / Reverse / Dedupe

    /// Sorts the selected lines by Unicode code order, stable for equal lines.
    /// `nil` when fewer than two lines or already in order.
    static func sortLines(text: String, selection: NSRange, ascending: Bool) -> Edit? {
        guard let b = multiLineBlock(text: text, selection: selection) else { return nil }
        let sorted = b.lines.enumerated().sorted { l, r in
            if l.element == r.element { return l.offset < r.offset }
            return ascending ? l.element < r.element : l.element > r.element
        }.map(\.element)
        guard sorted != b.lines else { return nil }
        return edit(b, lines: sorted)
    }

    static func reverseLines(text: String, selection: NSRange) -> Edit? {
        guard let b = multiLineBlock(text: text, selection: selection) else { return nil }
        return edit(b, lines: Array(b.lines.reversed()))
    }

    /// Keeps the first occurrence of each line. `nil` when nothing is removed.
    static func removeDuplicateLines(text: String, selection: NSRange) -> Edit? {
        let b = block(text: text, selection: selection, wholeDocumentIfEmpty: true)
        var seen = Set<String>()
        let kept = b.lines.filter { seen.insert($0).inserted }
        guard kept.count != b.lines.count else { return nil }
        return edit(b, lines: kept)
    }

    // MARK: - Trim

    /// Removes trailing spaces and tabs from every selected line (a caret acts
    /// on its own line). `nil` when nothing changes.
    static func trimTrailingWhitespace(text: String, selection: NSRange) -> Edit? {
        let b = block(text: text, selection: selection)
        let trimmed = b.lines.map { line -> String in
            var chars = Substring(line)
            var cr = ""
            if chars.hasSuffix("\r") { chars = chars.dropLast(); cr = "\r" }
            while let last = chars.last, last == " " || last == "\t" { chars = chars.dropLast() }
            return String(chars) + cr
        }
        guard trimmed != b.lines else { return nil }
        return edit(b, lines: trimmed)
    }

    // MARK: - Join (⌃J)

    /// Joins the selected lines (or the caret's line with the next) into one:
    /// the next line's leading whitespace is dropped and a single space is put
    /// between non-empty parts. The caret lands on the last join. `nil` at the
    /// end of the document.
    static func joinLines(text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        var b = block(text: text, selection: selection)
        if b.lines.count == 1 {
            guard NSMaxRange(b.range) < ns.length else { return nil }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(b.range), length: 0))
            let range = NSRange(location: b.range.location, length: NSMaxRange(next) - b.range.location)
            var content = ns.substring(with: range)
            let nl = content.hasSuffix("\n")
            if nl { content.removeLast() }
            b = Block(range: range, lines: content.components(separatedBy: "\n"), endsWithNewline: nl)
        }
        var result = b.lines[0]
        var caret = (result as NSString).length
        for line in b.lines.dropFirst() {
            let stripped = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            if !result.isEmpty, !stripped.isEmpty, result.last != " ", result.last != "\t" { result += " " }
            caret = (result as NSString).length
            result += stripped
        }
        return Edit(range: b.range, replacement: result + (b.endsWithNewline ? "\n" : ""),
                    newSelection: NSRange(location: b.range.location + caret, length: 0))
    }

    // MARK: - Case transforms

    /// Upper/lower/title-cases `selection`; an empty selection uses the word
    /// touching the caret. `nil` when there is nothing to change.
    static func transformCase(text: String, selection: NSRange, to transform: LineTransform) -> Edit? {
        let ns = text as NSString
        guard NSMaxRange(selection) <= ns.length else { return nil }
        var target = selection
        if target.length == 0 {
            func isWord(_ i: Int) -> Bool {
                let c = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: i))
                return c.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            }
            var s = target.location, e = target.location
            while s > 0, isWord(s - 1) { s = ns.rangeOfComposedCharacterSequence(at: s - 1).location }
            while e < ns.length, isWord(e) { e = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: e)) }
            target = NSRange(location: s, length: e - s)
        }
        guard target.length > 0 else { return nil }
        let original = ns.substring(with: target)
        let changed: String
        switch transform {
        case .uppercase: changed = original.uppercased()
        case .lowercase: changed = original.lowercased()
        case .titlecase: changed = titleCased(original)
        default: return nil
        }
        guard changed != original else { return nil }
        let len = (changed as NSString).length
        let newSel = selection.length == 0
            ? NSRange(location: selection.location + len - target.length, length: 0)
            : NSRange(location: target.location, length: len)
        return Edit(range: target, replacement: changed, newSelection: newSel)
    }

    /// First letter of each word upper, the rest lower. A word is a run of
    /// letters, digits, `'` and `_`.
    static func titleCased(_ s: String) -> String {
        var out = ""
        var inWord = false
        for ch in s {
            let isWordChar = ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" || ch == "_"
            if isWordChar {
                out += inWord ? ch.lowercased() : ch.uppercased()
                inWord = true
            } else {
                out.append(ch)
                inWord = false
            }
        }
        return out
    }

    // MARK: - Applying a command to many ranges

    /// Result of running a per-range edit over every range of a multi-selection.
    struct MultiEdit: Sendable, Equatable {
        /// Original-coordinate edits, last range first, so applying them in
        /// order never invalidates a later edit's range.
        let edits: [Edit]
        /// Selections to set once all edits are applied, in document order.
        let selections: [NSRange]
    }

    /// Runs `op` once per range. Ranges yielding no edit keep their selection
    /// (shifted by earlier edits). Ranges must not overlap.
    static func applyEach(
        text: String, ranges: [NSRange], op: (String, NSRange) -> Edit?
    ) -> MultiEdit? {
        let sorted = ranges.sorted { $0.location < $1.location }
        // An edit overlapping the previous one (two carets on one line) is dropped.
        var lastEnd = -1
        let edits = sorted.map { r -> Edit? in
            guard let e = op(text, r), e.range.location >= lastEnd else { return nil }
            lastEnd = NSMaxRange(e.range)
            return e
        }
        guard edits.contains(where: { $0 != nil }) else { return nil }
        var delta = 0
        var selections: [NSRange] = []
        for (r, e) in zip(sorted, edits) {
            if let e {
                selections.append(NSRange(location: e.newSelection.location + delta, length: e.newSelection.length))
                delta += (e.replacement as NSString).length - e.range.length
            } else {
                selections.append(NSRange(location: r.location + delta, length: r.length))
            }
        }
        return MultiEdit(edits: Array(edits.compactMap { $0 }.reversed()), selections: selections)
    }
}
