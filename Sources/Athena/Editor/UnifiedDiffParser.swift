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

// MARK: - GitLineChangeType

/// Per-line classification of a working-tree change relative to `HEAD`,
/// derived from a `ParsedDiff` by `UnifiedDiffParser.classifyLineChanges(in:)`
/// — feeds `GutterView`'s colored change bar (plan.md item 19, "D4"). Keyed
/// by 1-based *new* (working-tree) line number.
enum GitLineChangeType: Sendable, Equatable {
    /// A line added by this change, with no old-file counterpart.
    case added
    /// A line that replaces an old line 1:1 — a removed and an added line
    /// paired within the same contiguous change block.
    case modified
    /// Lines were removed here with nothing added in their place. Rendered
    /// as a single boundary marker on the next kept new-file line (or, at
    /// the end of a hunk, the last known new-file line) rather than
    /// needing a line of its own — matching how VS Code and other editors
    /// draw a "lines deleted here" notch rather than a full-height bar.
    case deleted
}

extension UnifiedDiffParser {

    /// Reduces a `ParsedDiff` to one `GitLineChangeType` per changed
    /// new-file line — the pure classification step `GutterView`'s change
    /// bar is driven from (see `AppState.refreshGitLineChanges(for:)`).
    ///
    /// Each hunk is walked in contiguous "changed" runs — consecutive
    /// non-context lines between two kept (context) lines:
    /// - A run with only added lines → every added line is `.added`.
    /// - A run mixing removed and added lines → the first
    ///   `min(removed.count, added.count)` added lines pair 1:1 with a
    ///   removed line and are `.modified`; any unpaired excess addition
    ///   (when there are more added than removed lines) is `.added`. Any
    ///   unpaired excess *removal* in a mixed run is not separately
    ///   marked — the `.modified`/`.added` bar already conveys "this hunk
    ///   changed here", which is enough fidelity without risking a
    ///   `.deleted` marker landing on (and being overwritten by) a line
    ///   this same run already classified.
    /// - A run with only removed lines → pure deletion, `.deleted`.
    static func classifyLineChanges(in diff: ParsedDiff) -> [Int: GitLineChangeType] {
        var result: [Int: GitLineChangeType] = [:]

        for hunk in diff.hunks {
            let lines = hunk.lines
            var index = 0
            var lastNewLine = hunk.newStart - 1

            while index < lines.count {
                let line = lines[index]
                if line.kind == .context {
                    lastNewLine = line.newLineNumber ?? lastNewLine
                    index += 1
                    continue
                }

                // Collect the full contiguous run of non-context lines
                // starting here — by construction this can't straddle a
                // context line, so a "pure removal" run and a "has
                // additions" run never abut without a kept line between
                // them (see the doc comment above).
                var j = index
                var removed: [DiffLine] = []
                var added:   [DiffLine] = []
                while j < lines.count, lines[j].kind != .context {
                    if lines[j].kind == .removed { removed.append(lines[j]) }
                    else                          { added.append(lines[j]) }
                    j += 1
                }

                if added.isEmpty {
                    let anchor = (j < lines.count ? lines[j].newLineNumber : nil) ?? (lastNewLine + 1)
                    if result[anchor] == nil { result[anchor] = .deleted }
                } else {
                    let pairedCount = min(removed.count, added.count)
                    for k in 0..<pairedCount {
                        if let n = added[k].newLineNumber { result[n] = .modified }
                    }
                    for k in pairedCount..<added.count {
                        if let n = added[k].newLineNumber { result[n] = .added }
                    }
                    lastNewLine = added.last?.newLineNumber ?? lastNewLine
                }

                index = j
            }
        }

        return result
    }
}
