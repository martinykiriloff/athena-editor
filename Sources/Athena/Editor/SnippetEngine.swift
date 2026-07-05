// SnippetEngine.swift
// Athena — minimal VS Code-style snippet parser/expander for completion insert-text.
// Swift 6, strict concurrency.

import Foundation

// MARK: - SnippetTabStop

/// One parsed/expanded tab stop: its stable stop number (`0` is always the
/// final cursor position) and its `NSRange` (UTF-16 offsets, matching every
/// other range convention in this codebase) within the expanded plain text.
struct SnippetTabStop: Sendable, Equatable {
    let index: Int
    var range: NSRange
}

// MARK: - ExpandedSnippet

/// Result of expanding a snippet body into plain text plus its tab stops,
/// already ordered for Tab-cycling: ascending numeric stop order, with the
/// final `$0` stop always last.
struct ExpandedSnippet: Sendable, Equatable {
    let text: String

    /// Empty when `source` had no `$`-markers at all — plain literal text.
    /// Callers should treat that exactly like a flat-text insertion (no
    /// tab-stop tracking to set up).
    let tabStops: [SnippetTabStop]
}

// MARK: - SnippetEngine

/// Parses and expands a small, self-contained subset of VS Code's snippet
/// grammar used by completion `insertText`:
///   - `$1`, `$2`, … — ordered tab stops, visited in ascending numeric order.
///   - `${1:placeholder}` — a tab stop with default text, selected on arrival
///     so typing overwrites it (the caller is expected to select the
///     resulting range post-insertion, mirroring the editor's existing
///     bracket-wrap-selection behavior).
///   - `$0` — the final cursor position after the last stop; defaults to the
///     end of the expanded text when absent.
///
/// Nested/mirrored placeholders (the same stop number appearing twice) and
/// transforms are explicitly out of scope (plan.md item 16, "B5") — linear
/// ordered tab stops with optional placeholder text cover the realistic
/// completion snippets this app authors.
enum SnippetEngine {

    /// Expands `source`. Always succeeds: text with no `$`-markers expands
    /// to itself with an empty `tabStops` array.
    static func expand(_ source: String) -> ExpandedSnippet {
        var result = ""
        result.reserveCapacity(source.count)
        var stops: [Int: NSRange] = [:]
        var sawFinalStop = false

        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "$", i + 1 < chars.count else {
                result.append(c)
                i += 1
                continue
            }

            let next = chars[i + 1]
            if next == "{", let parsed = parseBraced(chars, from: i + 2) {
                let start = result.utf16.count
                result += parsed.placeholder
                stops[parsed.stopNumber] = NSRange(location: start, length: parsed.placeholder.utf16.count)
                if parsed.stopNumber == 0 { sawFinalStop = true }
                i += 2 + parsed.consumedLength
                continue
            }
            if next.isNumber {
                var j = i + 1
                var digits = ""
                while j < chars.count, chars[j].isNumber {
                    digits.append(chars[j])
                    j += 1
                }
                if let stopNumber = Int(digits) {
                    let start = result.utf16.count
                    stops[stopNumber] = NSRange(location: start, length: 0)
                    if stopNumber == 0 { sawFinalStop = true }
                    i = j
                    continue
                }
            }

            // "$" wasn't followed by a recognized tab-stop shape — literal.
            result.append(c)
            i += 1
        }

        guard !stops.isEmpty else {
            return ExpandedSnippet(text: result, tabStops: [])
        }
        if !sawFinalStop {
            stops[0] = NSRange(location: result.utf16.count, length: 0)
        }

        let numberedStops = stops.keys.filter { $0 != 0 }.sorted()
            .map { SnippetTabStop(index: $0, range: stops[$0]!) }
        let finalStop = SnippetTabStop(index: 0, range: stops[0]!)
        return ExpandedSnippet(text: result, tabStops: numberedStops + [finalStop])
    }

    // MARK: - Private helpers

    /// Parses `N:placeholder}` or `N}` immediately following a `${`.
    /// Returns the stop number, its placeholder text (empty when there's no
    /// `:`), and how many characters — starting right after the leading
    /// `${` — were consumed, including the closing `}`. Returns `nil` when
    /// the shape isn't well-formed, so the caller falls back to emitting the
    /// `$` literally.
    private static func parseBraced(
        _ chars: [Character], from start: Int
    ) -> (stopNumber: Int, placeholder: String, consumedLength: Int)? {
        var j = start
        var digits = ""
        while j < chars.count, chars[j].isNumber {
            digits.append(chars[j])
            j += 1
        }
        guard !digits.isEmpty, let stopNumber = Int(digits) else { return nil }

        var placeholder = ""
        if j < chars.count, chars[j] == ":" {
            j += 1
            while j < chars.count, chars[j] != "}" {
                placeholder.append(chars[j])
                j += 1
            }
        }
        guard j < chars.count, chars[j] == "}" else { return nil }
        j += 1
        return (stopNumber, placeholder, j - start)
    }
}
