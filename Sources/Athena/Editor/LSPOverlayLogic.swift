// LSPOverlayLogic.swift
// Athena — pure helpers behind the LSP editor overlays: hint text, token colours, linked-edit mirroring.
// Swift 6, strict concurrency.

import Foundation

// MARK: - Position conversion

enum LSPPositions {
    /// Start offset of every line of `text` (UTF-16).
    static func lineStarts(_ text: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        while i < text.length {
            if text.character(at: i) == 0x0A { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    /// UTF-16 offset for a 0-based position, clamped to the end of its line.
    static func offset(line: Int, character: Int, text: NSString, lineStarts: [Int]) -> Int? {
        guard lineStarts.indices.contains(line) else { return nil }
        let start = lineStarts[line]
        let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : text.length
        return min(start + max(character, 0), lineEnd)
    }

    static func range(_ span: LSPRangeSpan, text: NSString, lineStarts: [Int]) -> NSRange? {
        guard let s = offset(line: span.startLine, character: span.startCharacter, text: text, lineStarts: lineStarts),
              let e = offset(line: span.endLine, character: span.endCharacter, text: text, lineStarts: lineStarts),
              e >= s else { return nil }
        return NSRange(location: s, length: e - s)
    }
}

// MARK: - Inlay hint text

enum InlayHintFormatter {
    static let maxHintsPerLine = 6
    static let maxLineLength = 120

    /// One dim string per line. A type hint (`: string`) is prefixed with the
    /// identifier it follows so it still reads correctly at the end of the line.
    static func lineTexts(hints: [InlayHint], text: NSString, lineStarts: [Int]) -> [Int: String] {
        var perLine: [Int: [InlayHint]] = [:]
        for hint in hints { perLine[hint.line, default: []].append(hint) }
        var out: [Int: String] = [:]
        for (line, lineHints) in perLine {
            let ordered = lineHints.sorted { $0.character < $1.character }.prefix(maxHintsPerLine)
            let parts = ordered.map { hint -> String in
                let label = hint.label.trimmingCharacters(in: .whitespaces)
                guard hint.kind == 1, label.hasPrefix(":"),
                      let at = LSPPositions.offset(line: hint.line, character: hint.character, text: text, lineStarts: lineStarts),
                      let name = identifier(endingAt: at, in: text) else { return label }
                return name + label
            }
            var joined = parts.joined(separator: "  ")
            if joined.count > maxLineLength { joined = String(joined.prefix(maxLineLength - 1)) + "…" }
            if !joined.isEmpty { out[line] = joined }
        }
        return out
    }

    static func identifier(endingAt offset: Int, in text: NSString) -> String? {
        var start = offset
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)),
              CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$" {
            start -= 1
        }
        return start < offset ? text.substring(with: NSRange(location: start, length: offset - start)) : nil
    }
}

// MARK: - Semantic token styling

enum SemanticTokenCategory: Equatable {
    case type, function, keyword, string, number, comment, annotation
}

enum SemanticTokenStyle {
    /// Which theme colour a token type maps to. Variables, parameters and
    /// properties return nil: the regex highlighter's plain colour stays.
    static func category(forType type: String, modifiers: [String]) -> SemanticTokenCategory? {
        switch type {
        case "namespace", "type", "class", "enum", "interface", "struct", "typeParameter": return .type
        case "function", "method", "macro": return .function
        case "keyword", "modifier": return .keyword
        case "string", "regexp": return .string
        case "number": return .number
        case "comment": return .comment
        case "decorator": return .annotation
        default: return nil
        }
    }

    /// Token spans as character ranges for text that still has the length the
    /// tokens were computed for.
    static func ranges(for spans: [SemanticTokenSpan], text: NSString, lineStarts: [Int])
        -> [(range: NSRange, category: SemanticTokenCategory)] {
        spans.compactMap { span in
            guard let category = category(forType: span.tokenType, modifiers: span.modifiers),
                  let start = LSPPositions.offset(line: span.line, character: span.startCharacter, text: text, lineStarts: lineStarts)
            else { return nil }
            let lineEnd = span.line + 1 < lineStarts.count ? lineStarts[span.line + 1] - 1 : text.length
            let end = min(start + span.length, lineEnd)
            return end > start ? (NSRange(location: start, length: end - start), category) : nil
        }
    }
}

// MARK: - Linked editing

enum LinkedEditingMirror {
    struct Plan: Equatable {
        /// Replacements for the other linked ranges, in post-edit coordinates.
        var edits: [(range: NSRange, text: String)]
        /// All linked ranges after the edits are applied.
        var finalRanges: [NSRange]
        static func == (a: Plan, b: Plan) -> Bool {
            a.finalRanges == b.finalRanges && a.edits.count == b.edits.count
                && zip(a.edits, b.edits).allSatisfy { $0.range == $1.range && $0.text == $1.text }
        }
    }

    /// Plans how to mirror a user edit onto the other linked ranges.
    /// - ranges: linked ranges in pre-edit coordinates
    /// - edited: range of the inserted text in post-edit coordinates
    /// - delta: change in document length caused by the edit
    /// - postText: the document after the edit
    /// Returns nil when the edit is not entirely inside one linked range, or
    /// the resulting word violates `wordPattern` (mirroring should stop).
    static func plan(ranges: [NSRange], edited: NSRange, delta: Int, postText: NSString, wordPattern: String?) -> Plan? {
        let replaced = NSRange(location: edited.location, length: edited.length - delta)
        guard replaced.length >= 0,
              let k = ranges.firstIndex(where: { $0.location <= replaced.location && NSMaxRange(replaced) <= NSMaxRange($0) })
        else { return nil }

        var shifted = ranges
        for i in ranges.indices {
            if i == k { shifted[i].length += delta }
            else if ranges[i].location >= NSMaxRange(ranges[k]) { shifted[i].location += delta }
        }
        guard shifted.allSatisfy({ $0.length >= 0 && NSMaxRange($0) <= postText.length }) else { return nil }

        let word = postText.substring(with: shifted[k])
        if let pattern = wordPattern, !pattern.isEmpty, !word.isEmpty {
            guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$"),
                  regex.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) != nil
            else { return nil }
        }

        let wordLength = (word as NSString).length
        var edits: [(range: NSRange, text: String)] = []
        for i in shifted.indices where i != k && postText.substring(with: shifted[i]) != word {
            edits.append((shifted[i], word))
        }
        let final = shifted.map { r -> NSRange in
            let before = edits.filter { $0.range.location < r.location }.reduce(0) { $0 + wordLength - $1.range.length }
            return NSRange(location: r.location + before, length: wordLength)
        }
        return Plan(edits: edits, finalRanges: final)
    }
}
