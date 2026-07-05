// FindReplaceController.swift
// Athena — drives the in-file find/replace bar directly against an NSTextView's
// NSTextStorage, replacing AppKit's NSTextFinder (find-only, no usable replace UI).
// Swift 6, strict concurrency.

@preconcurrency import AppKit

// MARK: - FindReplaceController

/// Owns the state and match-highlighting for the custom find/replace bar
/// (`FindReplaceBarView`). Created per-editor in `EditorView.makeNSView` and
/// exposed to SwiftUI the same way `EditorScrollProxy` is: stashed on the
/// coordinator for internal use, and published out through a `Binding` so the
/// surrounding SwiftUI view can render the bar and read its `@Observable` state.
@Observable
@MainActor
final class FindReplaceController {

    // MARK: Bar visibility

    var isVisible: Bool = false
    var showReplace: Bool = false

    // MARK: Query state

    // Plain stored properties, no property observers: `FindReplaceBarView`
    // calls `updateMatches()` explicitly on every change (mirroring
    // `SearchPanelView`'s `.onChange(of:) { scheduleDebounce() }` pattern)
    // rather than relying on `didSet` firing through the `@Observable` macro.
    var query: String = ""
    var replacement: String = ""
    var useRegex: Bool = false
    var caseSensitive: Bool = false
    var wholeWord: Bool = false

    // MARK: Match results

    private(set) var matches: [NSRange] = []
    private(set) var currentMatchIndex: Int = 0
    /// Set when the current query is regex mode and fails to compile.
    private(set) var isPatternInvalid: Bool = false

    var statusText: String {
        if query.isEmpty { return "" }
        if isPatternInvalid { return "Invalid pattern" }
        return matches.isEmpty ? "No results" : "\(currentMatchIndex + 1) of \(matches.count)"
    }

    // MARK: Wiring

    weak var textView: NSTextView?

    /// Bumped on every `present` call, including re-invocations while the bar
    /// is already visible (e.g. ⌘F pressed again while the replace field has
    /// focus) — `FindReplaceBarView` observes this to (re)focus the query
    /// field even when its own `onAppear` won't fire again.
    private(set) var focusRequestToken: Int = 0

    // MARK: - Presentation

    /// Shows the bar, expanding the replace row if requested. Seeds the query
    /// from the current selection (matching VS Code) the first time the bar
    /// is opened with no query yet.
    func present(withReplace: Bool) {
        if withReplace { showReplace = true }
        isVisible = true
        focusRequestToken += 1
        if query.isEmpty, let tv = textView {
            let selected = tv.selectedRange()
            if selected.length > 0, selected.length < 500 {
                query = (tv.string as NSString).substring(with: selected)
            }
        }
        updateMatches()
    }

    func dismiss() {
        isVisible = false
        clearHighlights()
        if let tv = textView, tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
        }
    }

    // MARK: - Matching

    /// Recomputes match ranges for the current query/options against the
    /// live text view content, keeps the "current" index near the last one
    /// (or the caret, the first time), and repaints highlights.
    func updateMatches() {
        guard let tv = textView else {
            matches = []
            isPatternInvalid = false
            return
        }
        guard !query.isEmpty else {
            matches = []
            currentMatchIndex = 0
            isPatternInvalid = false
            clearHighlights()
            return
        }
        guard let matcher = TextSearchMatcher(
            query: query, isRegex: useRegex, caseSensitive: caseSensitive, wholeWord: wholeWord
        ) else {
            matches = []
            currentMatchIndex = 0
            isPatternInvalid = useRegex
            clearHighlights()
            return
        }
        isPatternInvalid = false

        let anchor = matches.indices.contains(currentMatchIndex)
            ? matches[currentMatchIndex].location
            : tv.selectedRange().location

        matches = matcher.matches(in: tv.string)
        guard !matches.isEmpty else {
            currentMatchIndex = 0
            applyHighlights()
            return
        }
        currentMatchIndex = matches.firstIndex(where: { $0.location >= anchor }) ?? 0
        tv.setSelectedRange(matches[currentMatchIndex])
        tv.scrollRangeToVisible(matches[currentMatchIndex])
        applyHighlights()
    }

    func selectNext() {
        guard !matches.isEmpty else { return }
        selectMatch(at: (currentMatchIndex + 1) % matches.count)
    }

    func selectPrevious() {
        guard !matches.isEmpty else { return }
        selectMatch(at: (currentMatchIndex - 1 + matches.count) % matches.count)
    }

    // MARK: - Replace

    /// Replaces the current match and advances to the one that slides into
    /// its place. Returns `false` if there was nothing to replace.
    @discardableResult
    func replaceCurrent() -> Bool {
        guard let tv = textView, matches.indices.contains(currentMatchIndex),
              let matcher = TextSearchMatcher(
                  query: query, isRegex: useRegex, caseSensitive: caseSensitive, wholeWord: wholeWord
              )
        else { return false }

        let range = matches[currentMatchIndex]
        let newText = matcher.replacementText(forMatchIn: tv.string, range: range, replacement: replacement)
        replace(range, with: newText, in: tv)
        updateMatches()
        return true
    }

    /// Replaces every match in the file in one undo step. Returns the number
    /// of replacements made.
    @discardableResult
    func replaceAll() -> Int {
        guard let tv = textView,
              let matcher = TextSearchMatcher(
                  query: query, isRegex: useRegex, caseSensitive: caseSensitive, wholeWord: wholeWord
              )
        else { return 0 }

        let original = tv.string
        let (result, count) = matcher.replacingAll(in: original, with: replacement)
        guard count > 0 else { return 0 }

        let full = NSRange(location: 0, length: (original as NSString).length)
        replace(full, with: result, in: tv)
        updateMatches()
        return count
    }

    // MARK: - Private

    private func selectMatch(at index: Int) {
        guard let tv = textView, matches.indices.contains(index) else { return }
        currentMatchIndex = index
        tv.setSelectedRange(matches[index])
        tv.scrollRangeToVisible(matches[index])
        applyHighlights()
    }

    /// Replaces `range` with `text` through the undo-aware path so the edit
    /// groups with the rest of the file's undo stack and fires
    /// `textDidChange` (keeping the bound tab content and syntax
    /// highlighting in sync), mirroring `EditorView.Coordinator.replace`.
    private func replace(_ range: NSRange, with text: String, in tv: NSTextView) {
        guard tv.shouldChangeText(in: range, replacementString: text) else { return }
        tv.replaceCharacters(in: range, with: text)
        tv.didChangeText()
    }

    /// Highlights every match via temporary layout-manager attributes (not
    /// `NSTextStorage`, so it can't be clobbered by — or clobber — syntax
    /// highlighting, and never touches the undo stack).
    private func applyHighlights() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        clearHighlights()
        guard isVisible else { return }
        for (index, range) in matches.enumerated() {
            let color: NSColor = index == currentMatchIndex
                ? NSColor.findHighlightColor
                : NSColor.findHighlightColor.withAlphaComponent(0.35)
            lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        }
    }

    private func clearHighlights() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
    }
}
