// IndentationStyle.swift
// Athena — infers a file's own indentation, so edits match what is already there.
// Swift 6, strict concurrency.

import Foundation

/// How a particular file is indented.
///
/// A project's files rarely match one global setting: a Makefile is tabs, a
/// Go file is tabs, most TypeScript is two spaces, some Python is four. The
/// editor's own preference is only the fallback for a file that shows no
/// evidence either way.
struct IndentationStyle: Sendable, Equatable {
    var usesSpaces: Bool
    /// Spaces per level. Meaningless for tabs beyond display width.
    var width: Int

    var unit: String { usesSpaces ? String(repeating: " ", count: max(1, width)) : "\t" }

    static let fourSpaces = IndentationStyle(usesSpaces: true, width: 4)

    /// Infers the style of `text`, or `nil` when nothing in it is indented.
    ///
    /// Tabs win on a simple majority of indented lines. For spaces the width
    /// is the most common *change* in indentation between consecutive
    /// indented lines, which is what actually reveals one level — counting
    /// absolute depths would call deeply nested two-space code "eight".
    static func detect(in text: String, sampleLimit: Int = 5_000) -> IndentationStyle? {
        var tabLines = 0
        var spaceLines = 0
        var deltaCounts: [Int: Int] = [:]
        var previousSpaceDepth: Int?
        var scanned = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if scanned >= sampleLimit { break }
            scanned += 1

            var spaces = 0
            var tabs = 0
            var sawContent = false
            for character in line {
                if character == " " { spaces += 1 }
                else if character == "\t" { tabs += 1 }
                else { sawContent = !character.isWhitespace; break }
            }
            // Blank lines and lines with no indentation tell us nothing.
            guard sawContent else { continue }

            if tabs > 0 && spaces == 0 {
                tabLines += 1
                previousSpaceDepth = nil
            } else if spaces > 0 && tabs == 0 {
                spaceLines += 1
                if let previous = previousSpaceDepth, spaces != previous {
                    let delta = abs(spaces - previous)
                    if (1...8).contains(delta) { deltaCounts[delta, default: 0] += 1 }
                }
                previousSpaceDepth = spaces
            }
        }

        if tabLines == 0 && spaceLines == 0 { return nil }
        if tabLines >= spaceLines { return IndentationStyle(usesSpaces: false, width: 4) }

        // Prefer the most common step; ties go to the smaller one, so code
        // that mixes 2 and 4 reads as 2 rather than flipping between runs.
        let width = deltaCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .first?.key
        return IndentationStyle(usesSpaces: true, width: width ?? 4)
    }
}
