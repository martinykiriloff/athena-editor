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
}
