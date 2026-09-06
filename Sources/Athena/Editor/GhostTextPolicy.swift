// GhostTextPolicy.swift
// Athena — decides when an AI inline suggestion is the right tool, and when
// the completion popup already is.
// Swift 6, strict concurrency.

import Foundation

enum GhostTextPolicy {

    /// Shortest single-line suggestion worth showing as ghost text.
    static let minimumSingleLineLength = 12

    /// Whether to ask the model for an inline suggestion at this caret.
    ///
    /// Finishing an identifier is the popup's job — it answers instantly
    /// from the language server and the buffer, with no network round trip
    /// and no flicker. The model is worth asking only where a whole line or
    /// block is what comes next: after a newline, a brace, an `=`, or a
    /// comment stating intent. That split is what keeps short completions
    /// deterministic while leaving method bodies and refactors to the model.
    static func shouldRequest(text: NSString, cursor: Int, isPopupVisible: Bool) -> Bool {
        guard !isPopupVisible else { return false }
        guard cursor > 0, cursor <= text.length else { return false }

        // Mid-identifier, or straight after ".": popup territory.
        let previous = text.character(at: cursor - 1)
        if isIdentifierCharacter(previous) || previous == 46 /* . */ { return false }

        // End of line only. Suggesting a block mid-line would have to
        // rewrite the code already to the right of the caret.
        var i = cursor
        while i < text.length {
            let c = text.character(at: i)
            if c == 0x0A { break }
            if !isSpace(c) { return false }
            i += 1
        }

        // Needs something to complete *from* — scanning back, so this
        // normally stops on the first character.
        var j = cursor - 1
        while j >= 0 {
            if !isWhitespace(text.character(at: j)) { return true }
            j -= 1
        }
        return false
    }

    /// The model sometimes answers a block request with one short token,
    /// which is precisely what the popup already offers faster and offline.
    /// Ghost text earns its interruption only when it spans a line or more.
    static func isSubstantial(_ suggestion: String) -> Bool {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("\n") { return true }
        return trimmed.count >= minimumSingleLineLength
    }

    // MARK: - Private

    private static func isIdentifierCharacter(_ c: unichar) -> Bool {
        c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57)
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    private static func isWhitespace(_ c: unichar) -> Bool {
        isSpace(c) || c == 0x0A || c == 0x0D
    }
}
