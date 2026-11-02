// HighlightPlanner.swift
// Athena — decides how much text to re-highlight after an edit (pure logic, unit-tested).
// Swift 6, strict concurrency.

import Foundation

// MARK: - HighlightPlanner

/// The regex highlighter has constructs that span lines (block comments,
/// template / triple-quoted strings, markdown fences, unbalanced quotes), so
/// re-highlighting only the edited line is not always correct. The planner
/// returns a small window (edited paragraph plus one neighbouring paragraph
/// each side) when that is equivalent to a whole-document pass for the tokens
/// involved, and `.full` otherwise. It errs on the side of `.full`.
enum HighlightPlanner {

    // MARK: Public API

    /// - Parameters:
    ///   - text: the document after the edit.
    ///   - edit: the edit, in post-edit coordinates.
    ///   - language: the document's language (selects the multi-line delimiters).
    ///   - isNewlineColored: whether the newline at a UTF-16 index currently
    ///     carries a token colour. Only a token that spans lines colours a
    ///     newline, so a coloured newline means a multi-line construct
    ///     crosses that point.
    static func plan(
        text: NSString,
        edit: HighlightEdit,
        language: Language,
        isNewlineColored: (Int) -> Bool
    ) -> HighlightPlan {
        let length = text.length
        guard edit.range.location != NSNotFound,
              edit.range.location >= 0,
              NSMaxRange(edit.range) <= length else { return .full }

        let window = paragraphWindow(in: text, around: edit.range)
        guard window.length > 0 else { return .window(window) }

        // 1. A multi-line token crossing the window boundary or running
        //    through it (it colours the newlines it spans).
        if window.location > 0, isNewlineColored(window.location - 1) { return .full }
        var i = window.location
        while i < NSMaxRange(window) {
            if isNewline(text.character(at: i)), isNewlineColored(i) { return .full }
            i += 1
        }

        // 2. Multi-line delimiters present in the window (e.g. `/*`, `-->`).
        for token in delimiters(for: language)
        where text.range(of: token, options: [], range: window).location != NSNotFound {
            return .full
        }

        // 3. Quote-like characters: strings may span lines, so only allow a
        //    window when quotes stay balanced across the edit.
        let inserted = text.substring(with: edit.range)
        let touched = inserted + edit.deletedText
        if touched.contains("\\") && containsAnyQuote(text, in: window) { return .full }
        for quote in ["\"", "'", "`"] where touched.contains(quote) {
            let remaining = unescapedCount(of: quote, in: text, range: window)
            if remaining % 2 != 0 { return .full }
            let added = inserted.components(separatedBy: quote).count - 1
            let removed = edit.deletedText.components(separatedBy: quote).count - 1
            if (remaining - added + removed) % 2 != 0 { return .full }
        }

        // 4. Language-specific tokens that can span lines.
        let sensitive = sensitiveCharacters(for: language)
        if !sensitive.isEmpty, touched.contains(where: { sensitive.contains($0) }) { return .full }

        return .window(window)
    }

    /// The edited paragraph(s) plus one paragraph before and after.
    static func paragraphWindow(in text: NSString, around range: NSRange) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(range.location, length)
        let clamped = NSRange(location: location, length: min(range.length, length - location))
        let edited = text.lineRange(for: clamped)
        var start = edited.location
        var end = NSMaxRange(edited)
        if start > 0 {
            start = text.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }
        if end < length {
            end = NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0)))
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Private helpers

    private static func isNewline(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 || c == 0x85
    }

    private static func delimiters(for language: Language) -> [String] {
        switch language {
        case .swift, .typescript, .javascript, .rust, .go, .css, .ds, .sql: return ["/*", "*/"]
        case .html, .vue, .svelte: return ["<!--", "-->"]
        case .isml:     return ["<!--", "-->", "--->"]
        case .python, .toml, .graphql: return ["\"\"\"", "'''"]
        case .markdown: return ["```"]
        case .php:      return ["/*", "*/", "<<<"]
        case .java, .kotlin: return ["/*", "*/", "\"\"\""]
        case .c, .cpp:  return ["/*", "*/", "R\""]
        case .ruby:     return ["=begin", "=end", "<<"]
        case .shell, .dockerfile: return ["<<"]
        case .json, .plaintext, .image, .yaml, .env: return []
        }
    }

    /// Characters whose edit can change a multi-line token for languages with
    /// patterns like `[^}]*` or `[^*]+` that run across newlines.
    private static func sensitiveCharacters(for language: Language) -> Set<Character> {
        switch language {
        case .markdown: return ["*", "`", "[", "]", "(", ")"]
        case .isml:     return ["{", "}", "$"]
        case .vue, .svelte: return ["{", "}"]
        default:        return []
        }
    }

    private static func containsAnyQuote(_ text: NSString, in range: NSRange) -> Bool {
        for q in ["\"", "'", "`"]
        where text.range(of: q, options: [], range: range).location != NSNotFound { return true }
        return false
    }

    /// Counts `quote` occurrences not preceded by an odd run of backslashes.
    private static func unescapedCount(of quote: String, in text: NSString, range: NSRange) -> Int {
        guard let q = quote.utf16.first else { return 0 }
        var count = 0
        var backslashes = 0
        var i = range.location
        while i < NSMaxRange(range) {
            let c = text.character(at: i)
            if c == 0x5C {
                backslashes += 1
            } else {
                if c == q, backslashes % 2 == 0 { count += 1 }
                backslashes = 0
            }
            i += 1
        }
        return count
    }
}
