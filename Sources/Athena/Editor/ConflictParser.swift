// ConflictParser.swift
// Athena — pure parser locating `<<<<<<< / ======= / >>>>>>>` merge-conflict
// regions in a file's text (plan.md item 23, "D5").
// Swift 6, strict concurrency.

import Foundation

// MARK: - ConflictRegion

/// One `<<<<<<< ours / ======= / >>>>>>> theirs` block found in a file's
/// text — everything needed to render the region's ours/theirs background
/// tints and to replace the whole thing (all three marker lines included)
/// with a chosen resolution in one undoable edit. Ranges are UTF-16
/// (`NSRange`) offsets into the exact text `ConflictParser.parse(_:)` was
/// given, computed the same way `LineOperations` computes its edit ranges
/// (`NSString.lineRange(for:)`), so they can be handed straight to
/// `NSTextView.replaceCharacters(in:with:)` with no further translation.
struct ConflictRegion: Sendable, Equatable {
    /// Text after the opening marker, e.g. `"HEAD"` in `"<<<<<<< HEAD"` —
    /// empty when git (or a hand-written conflict) omits it.
    let oursLabel: String
    /// Text after the closing marker, e.g. a branch name in
    /// `">>>>>>> feature-branch"`.
    let theirsLabel: String
    /// The "ours" content lines, joined by `"\n"` — never includes the
    /// `<<<<<<<`/`=======` marker lines themselves.
    let oursText: String
    /// The "theirs" content lines, joined by `"\n"` — never includes the
    /// `=======`/`>>>>>>>` marker lines themselves.
    let theirsText: String
    /// 1-based line number of the opening `<<<<<<<` marker.
    let startLine: Int
    /// 1-based line number of the closing `>>>>>>>` marker.
    let endLine: Int
    /// Spans every line in the region, `<<<<<<<` through `>>>>>>>`
    /// inclusive, terminator included where one follows — replacing this
    /// exact range removes all three marker lines along with the losing
    /// side's content.
    let range: NSRange
    /// The "ours" content lines only (excludes the `<<<<<<<` and `=======`
    /// marker lines) — used to paint just that span's background tint.
    let oursRange: NSRange
    /// The "theirs" content lines only (excludes the `=======` and
    /// `>>>>>>>` marker lines) — used to paint just that span's background tint.
    let theirsRange: NSRange
}

// MARK: - ConflictResolutionChoice

/// Which side(s) of a `ConflictRegion` to keep — the three "Accept …"
/// actions the gutter's conflict menu offers.
enum ConflictResolutionChoice: Sendable, Equatable {
    case ours
    case theirs
    case both
}

extension ConflictRegion {
    /// The replacement text for resolving this region with `choice` — what
    /// `range` gets replaced with. `.both` keeps ours then theirs,
    /// separated by a newline (omitting either side if it's empty, so
    /// accepting both when one side deleted the block entirely doesn't
    /// leave a stray blank line).
    func resolvedText(for choice: ConflictResolutionChoice) -> String {
        switch choice {
        case .ours:   return oursText
        case .theirs: return theirsText
        case .both:
            return [oursText, theirsText].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}

// MARK: - ConflictParser

/// Finds every well-formed conflict region in a file's text. Pure and
/// stateless — no `NSTextView`/AppKit dependency — so it's directly
/// unit-testable (see `ConflictParserTests`) and safe to re-run on every
/// keystroke the same way `SyntaxHighlighter` and `UnifiedDiffParser` are.
///
/// Detection is simply "`parse(_:)` returns at least one region" — a lone,
/// unmatched marker line (e.g. a stray `"<<<<<<<"` with no following
/// `"======="`/`">>>>>>>"`) is skipped rather than misparsed as a region,
/// matching git's own requirement that all three markers appear in order.
enum ConflictParser {

    /// One physical line of the source text: its 1-based line number, its
    /// content with the trailing line terminator stripped, and its full
    /// `NSRange` (terminator included) in the original text — computed via
    /// repeated `NSString.lineRange(for:)` calls, the same line-walking
    /// idiom `GutterView`/`EditorView.Coordinator` already use elsewhere in
    /// this codebase.
    private struct Line {
        let number: Int
        let range: NSRange
        let content: String
    }

    private static func lines(of text: String) -> [Line] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        var result: [Line] = []
        var idx = 0
        var number = 1
        while idx < ns.length {
            let r = ns.lineRange(for: NSRange(location: idx, length: 0))
            guard r.length > 0 else { break }
            var content = ns.substring(with: r)
            if content.hasSuffix("\n") { content.removeLast() }
            if content.hasSuffix("\r") { content.removeLast() }
            result.append(Line(number: number, range: r, content: content))
            idx = NSMaxRange(r)
            number += 1
        }
        return result
    }

    /// Marker length shared by all three of `<<<<<<<`/`=======`/`>>>>>>>` —
    /// used to strip the marker itself off to get a trailing label.
    private static let markerLength = 7

    private static func label(from lineContent: String) -> String {
        String(lineContent.dropFirst(markerLength)).trimmingCharacters(in: .whitespaces)
    }

    static func parse(_ text: String) -> [ConflictRegion] {
        let allLines = lines(of: text)
        var regions: [ConflictRegion] = []

        var i = 0
        while i < allLines.count {
            guard allLines[i].content.hasPrefix("<<<<<<<") else { i += 1; continue }
            let startLine = allLines[i]

            guard let sepIndex = (i + 1..<allLines.count)
                .first(where: { allLines[$0].content.hasPrefix("=======") })
            else { i += 1; continue }

            guard let endIndex = (sepIndex + 1..<allLines.count)
                .first(where: { allLines[$0].content.hasPrefix(">>>>>>>") })
            else { i += 1; continue }

            let endLine = allLines[endIndex]
            let oursLines   = allLines[(i + 1)..<sepIndex]
            let theirsLines = allLines[(sepIndex + 1)..<endIndex]

            let wholeRange = NSRange(
                location: startLine.range.location,
                length: NSMaxRange(endLine.range) - startLine.range.location
            )
            // An empty side (e.g. the separator immediately follows the
            // opening marker) still gets a valid, zero-length range
            // positioned right where its content would start — harmless to
            // paint (a zero-length background attribute is a no-op) and
            // keeps `oursRange`/`theirsRange` total functions of the region.
            let oursRange: NSRange
            if let first = oursLines.first, let last = oursLines.last {
                oursRange = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            } else {
                oursRange = NSRange(location: allLines[sepIndex].range.location, length: 0)
            }
            let theirsRange: NSRange
            if let first = theirsLines.first, let last = theirsLines.last {
                theirsRange = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            } else {
                theirsRange = NSRange(location: allLines[endIndex].range.location, length: 0)
            }

            regions.append(ConflictRegion(
                oursLabel: label(from: startLine.content),
                theirsLabel: label(from: endLine.content),
                oursText: oursLines.map(\.content).joined(separator: "\n"),
                theirsText: theirsLines.map(\.content).joined(separator: "\n"),
                startLine: startLine.number,
                endLine: endLine.number,
                range: wholeRange,
                oursRange: oursRange,
                theirsRange: theirsRange
            ))

            i = endIndex + 1
        }

        return regions
    }
}

// MARK: - ConflictRegion.compareDiff

extension ConflictRegion {
    /// Synthesizes a `ParsedDiff` treating "ours" as the old side and
    /// "theirs" as the new side, so the gutter menu's "Compare" action can
    /// reuse `DiffViewerView`/`DiffHunkView` (plan.md item 18) verbatim
    /// instead of a second diff renderer — the same "build a `ParsedDiff`
    /// by hand" move `ParsedDiff.wholeFileAsAdded` already makes for
    /// untracked files. Never touches disk or git: both sides are already
    /// sitting in memory as `oursText`/`theirsText`.
    var compareDiff: ParsedDiff {
        let oursLines   = oursText.isEmpty   ? [] : oursText.components(separatedBy: "\n")
        let theirsLines = theirsText.isEmpty ? [] : theirsText.components(separatedBy: "\n")
        guard !oursLines.isEmpty || !theirsLines.isEmpty else { return .empty }

        let removed = oursLines.enumerated().map {
            DiffLine(kind: .removed, oldLineNumber: $0.offset + 1, newLineNumber: nil, text: $0.element)
        }
        let added = theirsLines.enumerated().map {
            DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: $0.offset + 1, text: $0.element)
        }

        let hunk = DiffHunk(
            header: "@@ ours (\(oursLabel.isEmpty ? "HEAD" : oursLabel)) vs theirs (\(theirsLabel.isEmpty ? "incoming" : theirsLabel)) @@",
            oldStart: 1, oldCount: oursLines.count,
            newStart: 1, newCount: theirsLines.count,
            lines: removed + added
        )
        return ParsedDiff(hunks: [hunk], isBinary: false)
    }
}
