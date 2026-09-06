// BufferCompletionProvider.swift
// Athena — identifier completion drawn from the open buffer: the always-on
// source when no language server answers (JetBrains basic completion).
// Swift 6, strict concurrency.

import Foundation

/// One identifier found in the buffer, carrying the two signals JetBrains
/// ranks basic completion by: how often it appears, and how close its
/// nearest occurrence is to the caret.
struct BufferWord: Sendable, Equatable {
    var text: String
    var occurrences: Int
    /// Characters between the caret and the nearest occurrence.
    var nearestDistance: Int
}

/// Pure text scanning — no actor state, so it runs wherever the live buffer
/// is (the editor coordinator) rather than round-tripping through a service.
enum BufferCompletionProvider {

    /// Identifiers shorter than this are noise in a popup (`i`, `id`, `x`).
    static let minimumLength = 3
    /// Bounds the merge, not the display; the popup ranks and shows 20.
    static let maximumItems = 60
    /// Past this the scan is skipped rather than run on every keystroke of a
    /// pathological file.
    static let maximumScannedCharacters = 2_000_000

    /// Whether buffer words belong in the popup for this file.
    ///
    /// Off for prose and binary: Return accepts the popup's selection, so
    /// in Markdown a suggestion would swallow the keystroke that ends a
    /// paragraph. Semantic sources (a language server, Drizzle) are
    /// unaffected — this gates only the word scan. `nil` means an untitled
    /// buffer, which is exactly where nothing semantic is running yet.
    static func isEnabled(for language: Language?) -> Bool {
        switch language {
        case .markdown, .plaintext, .image: return false
        default: return true
        }
    }

    /// Every identifier in `text`, nearest-and-most-used first.
    ///
    /// `wordRange` is the partial word under the caret. That one occurrence
    /// is skipped, because the fragment being typed is not a suggestion for
    /// itself — but the same identifier elsewhere in the file still counts,
    /// which is exactly what makes the feature useful.
    static func words(in text: NSString, cursor: Int, wordRange: NSRange) -> [BufferWord] {
        let length = text.length
        guard length > 0, length <= maximumScannedCharacters else { return [] }

        var found: [String: (occurrences: Int, nearest: Int)] = [:]
        var start = 0
        var inWord = false

        func flush(end: Int) {
            guard inWord else { return }
            inWord = false
            let range = NSRange(location: start, length: end - start)
            guard range.length >= minimumLength else { return }
            guard !(range.location == wordRange.location && range.length == wordRange.length) else { return }

            let word = text.substring(with: range)
            let distance = range.location > cursor
                ? range.location - cursor
                : max(0, cursor - NSMaxRange(range))
            if let existing = found[word] {
                found[word] = (existing.occurrences + 1, min(existing.nearest, distance))
            } else {
                found[word] = (1, distance)
            }
        }

        for i in 0..<length {
            let c = text.character(at: i)
            let isStart = c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            let isBody  = isStart || (c >= 48 && c <= 57)
            if inWord {
                if !isBody { flush(end: i) }
            } else if isStart {
                inWord = true
                start = i
            }
        }
        flush(end: length)

        return found
            .map { BufferWord(text: $0.key, occurrences: $0.value.occurrences, nearestDistance: $0.value.nearest) }
            .sorted { a, b in
                if a.nearestDistance != b.nearestDistance { return a.nearestDistance < b.nearestDistance }
                if a.occurrences != b.occurrences { return a.occurrences > b.occurrences }
                return a.text < b.text
            }
    }

    /// Buffer words as completion items.
    ///
    /// `sortText` begins with "zz" so that when a buffer word and a semantic
    /// item score the same, the language server's item wins the tie: the
    /// buffer is the fallback, never the authority on what a symbol means.
    /// An entry identical to what the user already typed is dropped —
    /// accepting it would insert nothing.
    static func items(in text: NSString, cursor: Int, wordRange: NSRange) -> [CompletionItem] {
        let typed = wordRange.length > 0 && NSMaxRange(wordRange) <= text.length
            ? text.substring(with: wordRange)
            : ""
        var result: [CompletionItem] = []
        for word in words(in: text, cursor: cursor, wordRange: wordRange) where word.text != typed {
            result.append(CompletionItem(
                label: word.text,
                kind: "text",
                detail: "in file",
                insertText: word.text,
                sortText: String(format: "zz%04d", result.count)
            ))
            if result.count == maximumItems { break }
        }
        return result
    }
}
