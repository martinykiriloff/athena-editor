// GhostTextPolicy.swift
// Athena — decides when an AI inline suggestion is the right tool, and when
// the completion popup already is; plus the pure text rules ghost text uses.
// Swift 6, strict concurrency.

import Foundation

enum GhostTextPolicy {

    /// Shortest single-line suggestion worth showing as ghost text.
    static let minimumSingleLineLength = 12

    /// Characters that may sit to the right of the caret for a mid-line
    /// suggestion: closers an auto-pair inserted, and statement ends.
    private static let midLineClosers: Set<unichar> = [
        41, 93, 125,      // ) ] }
        34, 39, 96,       // " ' `
        59, 44, 62,       // ; , >
    ]

    /// Whether to ask the model for an inline suggestion at this caret.
    static func shouldRequest(text: NSString, cursor: Int, isPopupVisible: Bool) -> Bool {
        mode(text: text, cursor: cursor, isPopupVisible: isPopupVisible) != nil
    }

    /// The kind of suggestion to ask for at this caret, or `nil` to stay quiet.
    ///
    /// Finishing an identifier is the popup's job — it answers instantly
    /// from the language server and the buffer, with no network round trip
    /// and no flicker. The model is worth asking only where a whole line or
    /// block is what comes next: after a newline, a brace, an `=`, or a
    /// comment stating intent. `manual` (⌥\) drops the identifier rule —
    /// the user asked — but never the "something to complete from" rule.
    static func mode(
        text: NSString,
        cursor: Int,
        isPopupVisible: Bool,
        manual: Bool = false
    ) -> InlineCompletionMode? {
        guard !isPopupVisible else { return nil }
        guard cursor > 0, cursor <= text.length else { return nil }

        // Mid-identifier, or straight after ".": popup territory.
        let previous = text.character(at: cursor - 1)
        if !manual, isIdentifierCharacter(previous) || previous == 46 /* . */ { return nil }

        // Needs something to complete *from*.
        var j = cursor - 1
        var hasContent = false
        while j >= 0 {
            if !isWhitespace(text.character(at: j)) { hasContent = true; break }
            j -= 1
        }
        guard hasContent else { return nil }

        // What's to the right decides the mode: nothing (or spaces) is end
        // of line; only closing punctuation is mid-line; real code means a
        // suggestion would have to rewrite it, so stay quiet.
        var sawCloser = false
        var i = cursor
        while i < text.length {
            let c = text.character(at: i)
            if c == 0x0A || c == 0x0D { break }
            if isSpace(c) { i += 1; continue }
            guard midLineClosers.contains(c) else { return nil }
            sawCloser = true
            i += 1
        }
        return sawCloser ? .midLine : .endOfLine
    }

    /// The model sometimes answers a block request with one short token,
    /// which is precisely what the popup already offers faster and offline.
    /// Ghost text earns its interruption only when it spans a line or more.
    /// A manual request (⌥\) shows whatever came back.
    static func isSubstantial(_ suggestion: String, manual: Bool = false) -> Bool {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if manual { return true }
        if trimmed.contains("\n") { return true }
        return trimmed.count >= minimumSingleLineLength
    }

    // MARK: - Shaping a suggestion for its slot

    /// Fits a raw suggestion to the caret: mid-line keeps one line and drops
    /// the tail that repeats the closers already right of the caret (the
    /// model writes `bar)` when `)` is there); end of line drops a trailing
    /// repeat of the code that follows. Returns `nil` when nothing is left.
    static func fit(_ suggestion: String, mode: InlineCompletionMode, restOfLine: String, suffix: String) -> String? {
        var text = suggestion
        switch mode {
        case .midLine:
            if let newline = text.firstIndex(of: "\n") { text = String(text[..<newline]) }
            let rest = restOfLine.trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                text = trimTrailingOverlap(text, with: rest)
            }
            text = String(text.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        case .endOfLine:
            text = trimRepeatedSuffix(text, suffix: suffix)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Drops the longest tail of `text` that equals a head of `rest`, so a
    /// suggestion never duplicates the closers already on the line.
    static func trimTrailingOverlap(_ text: String, with rest: String) -> String {
        let maxLen = min(text.count, rest.count)
        guard maxLen > 0 else { return text }
        for len in stride(from: maxLen, through: 1, by: -1) {
            if text.hasSuffix(String(rest.prefix(len))) {
                return String(text.dropLast(len))
            }
        }
        return text
    }

    /// Models sometimes finish a block and then carry on into code that
    /// already follows the caret. Cut the suggestion where it starts
    /// repeating the next non-blank line of `suffix`.
    static func trimRepeatedSuffix(_ text: String, suffix: String) -> String {
        guard let nextLine = suffix
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }),
              nextLine.count >= 2
        else { return text }
        var lines = text.components(separatedBy: "\n")
        // Line 0 continues the caret's own line; only later lines can repeat.
        if lines.count > 1,
           let idx = lines.indices.dropFirst().first(where: {
               lines[$0].trimmingCharacters(in: .whitespaces) == nextLine
           }) {
            lines.removeSubrange(idx...)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Partial accept

    /// The next "word" of a suggestion for ⌘→, matching VS Code: leading
    /// whitespace plus one identifier run, or one run of punctuation.
    static func nextWordChunk(of suggestion: String) -> String {
        var chunk = ""
        var iterator = suggestion.makeIterator()
        var pending: Character? = iterator.next()
        // Leading whitespace (a newline ends the chunk, so a word never spans lines).
        while let c = pending, c == " " || c == "\t" {
            chunk.append(c); pending = iterator.next()
        }
        guard let first = pending else { return chunk }
        if first == "\n" { return chunk + "\n" }
        let wordLike = isWordCharacter(first)
        while let c = pending, c != "\n", c != " ", c != "\t", isWordCharacter(c) == wordLike {
            chunk.append(c); pending = iterator.next()
        }
        return chunk
    }

    /// The rest of the current suggestion line, including its newline.
    static func nextLineChunk(of suggestion: String) -> String {
        guard let newline = suggestion.firstIndex(of: "\n") else { return suggestion }
        return String(suggestion[...newline])
    }

    // MARK: - Private

    private static func isWordCharacter(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter || c.isNumber
    }

    private static func isIdentifierCharacter(_ c: unichar) -> Bool {
        c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57)
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    private static func isWhitespace(_ c: unichar) -> Bool {
        isSpace(c) || c == 0x0A || c == 0x0D
    }
}
