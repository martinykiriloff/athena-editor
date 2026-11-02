// FoldState.swift
// Athena — pure set of folded (hidden) character ranges with edit tracking. The text storage is
//           never modified; the layout manager just hides these ranges.
// Swift 6, strict concurrency.

import Foundation

/// Folded regions as UTF-16 ranges. Each range starts at the newline that
/// ends the fold's header line and stops before the newline that ends its
/// last hidden line, so the header, an ellipsis chip and whatever follows
/// the last hidden line stay on one visual line. Folds may nest.
struct FoldState: Equatable, Sendable {

    private(set) var folds: [NSRange] = []
    /// `folds` unioned into disjoint sorted ranges, for hit-testing.
    private(set) var merged: [NSRange] = []

    var isEmpty: Bool { folds.isEmpty }

    // MARK: - Mutation

    @discardableResult
    mutating func fold(_ range: NSRange) -> Bool {
        guard range.length > 0, !folds.contains(range) else { return false }
        folds.append(range)
        folds.sort { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
        rebuild()
        return true
    }

    @discardableResult
    mutating func unfold(_ range: NSRange) -> Bool {
        guard let i = folds.firstIndex(of: range) else { return false }
        folds.remove(at: i)
        rebuild()
        return true
    }

    mutating func removeAll() {
        folds = []
        merged = []
    }

    /// Updates ranges for a text edit. `edited` is the range of the new text
    /// (as `NSTextStorage` reports it) and `delta` the change in length. A
    /// fold untouched by the edit shifts or stays; one the edit touches is
    /// dropped (the text was changed under it, so it opens). Returns the
    /// dropped folds, in post-edit coordinates clamped to `newLength`.
    mutating func applyEdit(edited: NSRange, delta: Int, newLength: Int) -> [NSRange] {
        guard !folds.isEmpty else { return [] }
        let oldLocation = edited.location
        let oldEnd = edited.location + max(0, edited.length - delta)
        var kept: [NSRange] = []
        var dropped: [NSRange] = []
        for f in folds {
            let s = f.location, e = NSMaxRange(f)
            if oldEnd <= s {
                kept.append(NSRange(location: s + delta, length: f.length))
            } else if oldLocation > e {
                kept.append(f)
            } else {
                let loc = min(max(0, s), newLength)
                dropped.append(NSRange(location: loc, length: min(f.length, newLength - loc)))
            }
        }
        folds = kept
        rebuild()
        return dropped
    }

    // MARK: - Queries

    func isHidden(_ index: Int) -> Bool {
        var lo = 0, hi = merged.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = merged[mid]
            if index < r.location { hi = mid - 1 }
            else if index >= NSMaxRange(r) { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    /// Folds a caret/selection must not sit inside. A caret in `(start, end]`
    /// would insert into hidden text, so such folds should be opened. A
    /// selection that wholly contains a fold (select-all) leaves it alone.
    func folds(hiddenBy selection: NSRange) -> [NSRange] {
        folds.filter { f in
            let s = f.location, e = NSMaxRange(f)
            if selection.length == 0 { return selection.location > s && selection.location <= e }
            if selection.location <= s && NSMaxRange(selection) > e { return false }
            let a = selection.location, b = NSMaxRange(selection)
            return (a > s && a <= e) || (b > s && b <= e)
        }
    }

    private mutating func rebuild() {
        var out: [NSRange] = []
        for f in folds.sorted(by: { $0.location < $1.location }) {
            if let last = out.last, f.location <= NSMaxRange(last) {
                out[out.count - 1] = NSRange(location: last.location,
                                             length: max(NSMaxRange(last), NSMaxRange(f)) - last.location)
            } else {
                out.append(f)
            }
        }
        merged = out
    }

    // MARK: - Line ↔ character mapping

    /// The hidden range that folds `range`'s lines: from the newline ending
    /// `startLine` to the end (before the newline) of `endLine`.
    static func hiddenRange(for range: FoldRange, lineStarts: [Int], textLength: Int) -> NSRange? {
        guard range.startLine >= 0, range.endLine > range.startLine, range.endLine < lineStarts.count else { return nil }
        let start = lineStarts[range.startLine + 1] - 1            // the "\n" ending the header
        let end = range.endLine + 1 < lineStarts.count ? lineStarts[range.endLine + 1] - 1 : textLength
        guard end > start, start >= 0, end <= textLength else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
