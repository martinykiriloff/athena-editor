// ColumnSelection.swift
// Athena — pure box-selection and add-cursor-above/below geometry (VS Code parity).
// Swift 6, strict concurrency.

import Foundation

// MARK: - ColumnSelection

/// Produces the `NSRange` lists that go into `NSTextView.selectedRanges` for
/// column (box) selection and "add cursor above/below". Columns are counted in
/// composed character sequences (so an emoji is one column, never half a
/// surrogate pair), and are not tab-width aware.
enum ColumnSelection {

    /// A line/column in the document; both 0-based. `column` may exceed a short
    /// line's length (a "virtual" column) so moving up/down through short lines
    /// remembers where the box edge really is.
    struct Position: Sendable, Equatable {
        var line: Int
        var column: Int
    }

    struct State: Sendable, Equatable {
        var anchor: Position
        var head: Position
    }

    // MARK: Line geometry

    /// Start offsets of every line (always at least one), UTF-16.
    static func lineStarts(_ ns: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 0x0A { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    /// Content range of `line` (terminator excluded, `\r` excluded).
    private static func contentRange(_ ns: NSString, _ starts: [Int], line: Int) -> NSRange {
        let s = starts[line]
        var e = line + 1 < starts.count ? starts[line + 1] - 1 : ns.length
        if e > s, ns.character(at: e - 1) == 0x0D { e -= 1 }
        return NSRange(location: s, length: max(0, e - s))
    }

    /// Number of composed characters in `line`'s content.
    static func lineLength(_ ns: NSString, _ starts: [Int], line: Int) -> Int {
        let r = contentRange(ns, starts, line: line)
        var count = 0, i = r.location
        while i < NSMaxRange(r) { i = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: i)); count += 1 }
        return count
    }

    /// UTF-16 offset of `column` in `line`, clamped to the line's end.
    static func offset(_ ns: NSString, _ starts: [Int], line: Int, column: Int) -> Int {
        let r = contentRange(ns, starts, line: line)
        var i = r.location, c = 0
        while c < column, i < NSMaxRange(r) { i = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: i)); c += 1 }
        return min(i, NSMaxRange(r))
    }

    /// Line/column of a UTF-16 `offset`.
    static func position(_ ns: NSString, _ starts: [Int], offset: Int) -> Position {
        let off = max(0, min(offset, ns.length))
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= off { lo = mid } else { hi = mid - 1 }
        }
        var col = 0, i = starts[lo]
        while i < off { i = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: i)); col += 1 }
        return Position(line: lo, column: col)
    }

    // MARK: Box selection

    /// One range per line between the anchor's and head's lines, each spanning
    /// the box's columns clamped to that line's length. Ordered top to bottom.
    static func ranges(in text: String, state: State) -> [NSRange] {
        let ns = text as NSString
        let starts = lineStarts(ns)
        let first = max(0, min(state.anchor.line, state.head.line))
        let last = min(starts.count - 1, max(state.anchor.line, state.head.line))
        guard first <= last else { return [] }
        let c1 = min(state.anchor.column, state.head.column)
        let c2 = max(state.anchor.column, state.head.column)
        return (first...last).map { line in
            let a = offset(ns, starts, line: line, column: c1)
            let b = offset(ns, starts, line: line, column: c2)
            return NSRange(location: a, length: b - a)
        }
    }

    enum Direction: Sendable { case up, down, left, right }

    /// Moves the box's moving edge (the head) one step.
    static func moved(_ state: State, _ direction: Direction, in text: String) -> State {
        let ns = text as NSString
        let starts = lineStarts(ns)
        var s = state
        switch direction {
        case .up:    s.head.line = max(0, s.head.line - 1)
        case .down:  s.head.line = min(starts.count - 1, s.head.line + 1)
        case .left:  s.head.column = max(0, s.head.column - 1)
        case .right:
            let first = min(s.anchor.line, s.head.line), last = max(s.anchor.line, s.head.line)
            let widest = (first...last).map { lineLength(ns, starts, line: $0) }.max() ?? 0
            s.head.column = min(max(widest, s.head.column), s.head.column + 1)
        }
        return s
    }

    /// Box state equivalent to the current selection: anchor at the start of the
    /// first range, head at the end of the last. Used to start a keyboard box
    /// from an ordinary caret/selection.
    static func state(from ranges: [NSRange], in text: String) -> State? {
        guard let first = ranges.min(by: { $0.location < $1.location }),
              let last = ranges.max(by: { NSMaxRange($0) < NSMaxRange($1) }) else { return nil }
        let ns = text as NSString
        let starts = lineStarts(ns)
        return State(anchor: position(ns, starts, offset: first.location),
                     head: position(ns, starts, offset: NSMaxRange(last)))
    }

    /// Box state for a mouse drag between two character offsets.
    static func state(anchorOffset: Int, headOffset: Int, in text: String) -> State {
        let ns = text as NSString
        let starts = lineStarts(ns)
        return State(anchor: position(ns, starts, offset: anchorOffset),
                     head: position(ns, starts, offset: headOffset))
    }

    // MARK: Add cursor above / below

    /// Adds a caret one line above the topmost range (`up`) or below the
    /// bottommost (`down`), at the same column, clamped to the line. A
    /// single-line selection is mirrored at the same columns. Returns `ranges`
    /// unchanged at the document edge.
    static func addingCursor(to ranges: [NSRange], above: Bool, in text: String) -> [NSRange] {
        guard !ranges.isEmpty else { return ranges }
        let ns = text as NSString
        let starts = lineStarts(ns)
        let sorted = ranges.sorted { $0.location < $1.location }
        let source = above ? sorted.first! : sorted.last!
        let from = position(ns, starts, offset: source.location)
        let to = position(ns, starts, offset: NSMaxRange(source))
        let targetLine = (above ? from.line : to.line) + (above ? -1 : 1)
        guard targetLine >= 0, targetLine < starts.count else { return ranges }
        let a: Int, b: Int
        if from.line == to.line {
            a = offset(ns, starts, line: targetLine, column: from.column)
            b = offset(ns, starts, line: targetLine, column: to.column)
        } else {
            let col = above ? from.column : to.column
            a = offset(ns, starts, line: targetLine, column: col)
            b = a
        }
        let added = NSRange(location: a, length: b - a)
        guard !sorted.contains(added) else { return ranges }
        return (sorted + [added]).sorted { $0.location < $1.location }
    }
}
