// EditorCoordinator+Editing.swift
// Athena — Coordinator glue for tag auto-close/rename, Emmet, line transforms,
// add-cursor and column selection. All logic lives in the pure types it calls.
// Swift 6, strict concurrency.

@preconcurrency import AppKit

// MARK: - EditingState

/// Mutable state for the features below, held by the Coordinator as one object
/// so the hot `EditorView.swift` gains a single stored property.
@MainActor
final class EditingState {
    struct LinkedEdit {
        let pair: MarkupTags.NamePair
        let editRange: NSRange
        let replacementLength: Int
    }
    var linkedEdit: LinkedEdit?
    var isApplyingLinkedEdit = false
    /// The box the keyboard/mouse last produced; reused only while the live
    /// selection still equals it.
    var columnState: ColumnSelection.State?
}

// MARK: - Coordinator extension

extension EditorView.Coordinator {

    // MARK: Flavor / syntax

    private var markupFlavor: MarkupFlavor? {
        if let ext = parent.fileURL?.pathExtension, let f = MarkupFlavor.flavor(forPathExtension: ext) { return f }
        return parent.fileURL == nil && currentLanguage == .html ? .html : nil
    }

    // MARK: Tag auto-close

    /// Called for a typed `>`. Inserts `>` plus the closing tag and leaves the
    /// caret between them. Returns false (default insertion) when no closing
    /// tag is wanted.
    func handleTagAutoClose(in tv: NSTextView) -> Bool {
        guard let flavor = markupFlavor, tv.selectedRanges.count <= 1 else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0,
              let closing = MarkupTags.closingTag(afterTyping: sel.location, in: tv.string, flavor: flavor)
        else { return false }
        let text = ">" + closing
        guard tv.shouldChangeText(in: sel, replacementString: text) else { return false }
        tv.replaceCharacters(in: sel, with: text)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        return true
    }

    // MARK: Linked tag rename

    /// Call from `shouldChangeTextIn` (text still unedited).
    func recordLinkedTagEdit(in tv: NSTextView, affected: NSRange, replacement: String?) {
        editingState.linkedEdit = nil
        guard !editingState.isApplyingLinkedEdit, let flavor = markupFlavor, let replacement,
              tv.selectedRanges.count <= 1,
              let pair = MarkupTags.namePair(in: tv.string, flavor: flavor, touching: affected)
        else { return }
        editingState.linkedEdit = .init(pair: pair, editRange: affected,
                                        replacementLength: (replacement as NSString).length)
    }

    /// Call at the end of `textDidChange`: mirrors the renamed tag name onto
    /// its partner.
    func applyLinkedTagRename(in tv: NSTextView) {
        guard let linked = editingState.linkedEdit, let flavor = markupFlavor else { return }
        editingState.linkedEdit = nil
        guard !editingState.isApplyingLinkedEdit,
              let rename = MarkupTags.partnerRename(
                newText: tv.string, pair: linked.pair, editRange: linked.editRange,
                replacementLength: linked.replacementLength, flavor: flavor)
        else { return }
        var selection = tv.selectedRange()
        editingState.isApplyingLinkedEdit = true
        defer { editingState.isApplyingLinkedEdit = false }
        guard tv.shouldChangeText(in: rename.range, replacementString: rename.replacement) else { return }
        tv.replaceCharacters(in: rename.range, with: rename.replacement)
        tv.didChangeText()
        if rename.range.location < selection.location {
            selection.location += (rename.replacement as NSString).length - rename.range.length
        }
        tv.setSelectedRange(selection)
    }

    // MARK: Emmet (Tab)

    /// Expands the abbreviation before a single caret. Returns false when there
    /// is nothing to expand so Tab behaves normally.
    func expandEmmetAbbreviation(in tv: NSTextView) -> Bool {
        guard tv.selectedRanges.count <= 1 else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let syntax: EmmetSyntax
        if let flavor = markupFlavor { syntax = .markup(flavor) }
        else if currentLanguage == .css { syntax = .css }
        else { return false }
        let style = (currentDetectIndentation ? detectedIndentStyle : nil)
            ?? IndentationStyle(usesSpaces: currentInsertSpaces, width: currentTabSize)
        guard let result = Emmet.expansion(in: tv.string, caret: sel.location, syntax: syntax, indentUnit: style.unit)
        else { return false }
        guard tv.shouldChangeText(in: result.range, replacementString: result.snippet.text) else { return false }
        tv.replaceCharacters(in: result.range, with: result.snippet.text)
        tv.didChangeText()
        let origin = result.range.location
        let stops = result.snippet.tabStops.map {
            SnippetTabStop(index: $0.index, range: NSRange(location: $0.range.location + origin, length: $0.range.length))
        }
        if stops.isEmpty {
            tv.setSelectedRange(NSRange(location: origin + (result.snippet.text as NSString).length, length: 0))
        } else {
            beginSnippet(stops: stops, in: tv)
        }
        return true
    }

    // MARK: Line / case transforms

    func applyTransform(_ transform: LineTransform, in tv: NSTextView) {
        let ranges = tv.selectedRanges.map(\.rangeValue)
        let op: (String, NSRange) -> LineOperations.Edit?
        switch transform {
        case .sortAscending:  op = { LineOperations.sortLines(text: $0, selection: $1, ascending: true) }
        case .sortDescending: op = { LineOperations.sortLines(text: $0, selection: $1, ascending: false) }
        case .reverse:        op = { LineOperations.reverseLines(text: $0, selection: $1) }
        case .removeDuplicates: op = { LineOperations.removeDuplicateLines(text: $0, selection: $1) }
        case .trimTrailingWhitespace: op = { LineOperations.trimTrailingWhitespace(text: $0, selection: $1) }
        case .join:           op = { LineOperations.joinLines(text: $0, selection: $1) }
        case .uppercase, .lowercase, .titlecase:
            op = { LineOperations.transformCase(text: $0, selection: $1, to: transform) }
        }
        guard let multi = LineOperations.applyEach(text: tv.string, ranges: ranges, op: op) else { return }
        tv.undoManager?.beginUndoGrouping()
        for e in multi.edits {
            guard tv.shouldChangeText(in: e.range, replacementString: e.replacement) else { continue }
            tv.replaceCharacters(in: e.range, with: e.replacement)
            tv.didChangeText()
        }
        tv.undoManager?.endUndoGrouping()
        tv.setSelectedRanges(multi.selections.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
    }

    // MARK: Cursors / columns

    func insertCursor(above: Bool, in tv: NSTextView) {
        let ranges = tv.selectedRanges.map(\.rangeValue)
        let updated = ColumnSelection.addingCursor(to: ranges, above: above, in: tv.string)
        guard updated != ranges else { return }
        tv.setSelectedRanges(updated.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        if let edge = above ? updated.first : updated.last { tv.scrollRangeToVisible(edge) }
    }

    func columnSelect(_ direction: ColumnSelectDirection, in tv: NSTextView) {
        let text = tv.string
        let live = tv.selectedRanges.map(\.rangeValue)
        var state: ColumnSelection.State
        if let saved = editingState.columnState, ColumnSelection.ranges(in: text, state: saved) == live {
            state = saved
        } else if let fresh = ColumnSelection.state(from: live, in: text) {
            state = fresh
        } else { return }
        let step: ColumnSelection.Direction
        switch direction {
        case .up: step = .up
        case .down: step = .down
        case .left: step = .left
        case .right: step = .right
        }
        state = ColumnSelection.moved(state, step, in: text)
        applyColumnState(state, in: tv)
    }

    /// Mouse ⌥⇧-drag between two character offsets.
    func columnDrag(anchor: Int, head: Int, in tv: NSTextView) {
        applyColumnState(ColumnSelection.state(anchorOffset: anchor, headOffset: head, in: tv.string), in: tv)
    }

    private func applyColumnState(_ state: ColumnSelection.State, in tv: NSTextView) {
        let ranges = ColumnSelection.ranges(in: tv.string, state: state)
        guard !ranges.isEmpty else { return }
        editingState.columnState = state
        tv.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
    }
}
