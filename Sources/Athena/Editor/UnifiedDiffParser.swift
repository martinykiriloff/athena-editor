// UnifiedDiffParser.swift
// Athena — pure parser turning `git diff` unified-diff text into a
// structured, renderable model (plan.md item 18, "D2").
// Swift 6, strict concurrency.

import Foundation

// MARK: - DiffLine

/// One rendered line of a diff hunk. `text` never includes the leading
/// `+`/`-`/` ` marker byte — that's carried in `kind` instead, so the UI can
/// render its own gutter glyph/background rather than re-parsing the marker.
struct DiffLine: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case context
        case added
        case removed
    }

    let kind: Kind
    /// 1-based line number in the pre-image (old file). `nil` for `.added`
    /// lines, which don't exist in the old file.
    let oldLineNumber: Int?
    /// 1-based line number in the post-image (new file). `nil` for
    /// `.removed` lines, which don't exist in the new file.
    let newLineNumber: Int?
    let text: String
}

// MARK: - DiffHunk

/// One `@@ -a,b +c,d @@` hunk and the lines it contains.
struct DiffHunk: Sendable, Equatable {
    /// The raw hunk header line, e.g. `"@@ -12,6 +12,8 @@ func foo() {"` —
    /// kept verbatim (including any trailing function-context git appends)
    /// for display.
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffLine]
}

// MARK: - ParsedDiff

/// The result of parsing one file's `git diff` output.
struct ParsedDiff: Sendable, Equatable {
    let hunks: [DiffHunk]
    /// `true` when git reported "Binary files ... differ" instead of a
    /// text hunk — callers should show a placeholder, not attempt to render
    /// `hunks` (which is always empty in that case).
    let isBinary: Bool

    static let empty = ParsedDiff(hunks: [], isBinary: false)

    /// Synthesizes a diff for a file with no meaningful `git diff` output —
    /// an untracked file has nothing to diff against `HEAD`, so the whole
    /// file is rendered as a single all-green "added" hunk instead (see
    /// plan.md item 18 point 4).
    static func wholeFileAsAdded(_ content: String) -> ParsedDiff {
        // Splitting on "\n" (not `.components(separatedBy: .newlines)`) matches
        // `parse(_:)`'s own line-splitting so behavior is consistent between
        // the two code paths; a trailing newline yields one trailing empty
        // element, which we drop so an N-line file reports exactly N lines.
        var rawLines = content.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }

        let lines = rawLines.enumerated().map { index, line in
            DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: index + 1, text: line)
        }
        guard !lines.isEmpty else { return .empty }

        let hunk = DiffHunk(
            header: "@@ -0,0 +1,\(lines.count) @@",
            oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count,
            lines: lines
        )
        return ParsedDiff(hunks: [hunk], isBinary: false)
    }
}

// MARK: - UnifiedDiffParser

/// Parses `git diff`/`git diff --cached` unified-diff text. Pure and
/// stateless — no `NSTextView`/AppKit dependency — so it's directly
/// unit-testable (see `UnifiedDiffParserTests`).
enum UnifiedDiffParser {

    /// Matches a hunk header's `-oldStart[,oldCount] +newStart[,newCount]`
    /// portion; the count defaults to 1 when git omits it (single-line hunks).
    private static let hunkHeaderPattern = try! NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
    )

    static func parse(_ diffText: String) -> ParsedDiff {
        if diffText.contains("Binary files") && diffText.contains("differ") {
            return ParsedDiff(hunks: [], isBinary: true)
        }

        var hunks: [DiffHunk] = []

        var header:   String = ""
        var oldStart  = 0
        var oldCount  = 0
        var newStart  = 0
        var newCount  = 0
        var lines: [DiffLine] = []
        var inHunk = false

        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            guard inHunk else { return }
            hunks.append(DiffHunk(
                header: header, oldStart: oldStart, oldCount: oldCount,
                newStart: newStart, newCount: newCount, lines: lines
            ))
            lines = []
            inHunk = false
        }

        for rawLine in diffText.components(separatedBy: "\n") {
            if rawLine.hasPrefix("@@"), let parsed = parseHunkHeader(rawLine) {
                flushHunk()
                header   = rawLine
                oldStart = parsed.oldStart
                oldCount = parsed.oldCount
                newStart = parsed.newStart
                newCount = parsed.newCount
                oldLine  = parsed.oldStart
                newLine  = parsed.newStart
                inHunk   = true
                continue
            }

            // Everything before the first hunk (`diff --git`, `index`, `---`,
            // `+++`) or a stray line between hunks that isn't hunk content is
            // metadata, not a renderable diff line — skip it.
            guard inHunk else { continue }

            if rawLine.hasPrefix("\\") {
                // "\ No newline at end of file" — a marker, not a content line.
                continue
            } else if rawLine.hasPrefix("+") {
                lines.append(DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: newLine, text: String(rawLine.dropFirst())))
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                lines.append(DiffLine(kind: .removed, oldLineNumber: oldLine, newLineNumber: nil, text: String(rawLine.dropFirst())))
                oldLine += 1
            } else if rawLine.hasPrefix(" ") {
                lines.append(DiffLine(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: String(rawLine.dropFirst())))
                oldLine += 1
                newLine += 1
            }
            // A genuinely blank line in the file is still marked with a
            // leading " " by git (handled by the `.hasPrefix(" ")` branch
            // above) — a completely empty split element only occurs as the
            // trailing artifact of splitting text that ends in "\n" (or a
            // stray blank line between/after hunks), neither of which is
            // real diff content, so it's simply skipped.
        }
        flushHunk()

        return ParsedDiff(hunks: hunks, isBinary: false)
    }

    // MARK: - Hunk header parsing

    private static func parseHunkHeader(
        _ line: String
    ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let ns = line as NSString
        guard let match = hunkHeaderPattern.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }

        func intGroup(_ index: Int, default defaultValue: Int) -> Int {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return defaultValue }
            return Int(ns.substring(with: range)) ?? defaultValue
        }

        return (
            oldStart: intGroup(1, default: 0),
            oldCount: intGroup(2, default: 1),
            newStart: intGroup(3, default: 0),
            newCount: intGroup(4, default: 1)
        )
    }
}
