// FoldingRanges.swift
// Athena — pure fold-range computation: brace/bracket pairs and block comments (string- and
//           comment-aware) or indentation, plus LSP range normalisation and nesting levels.
// Swift 6, strict concurrency.

import Foundation

// MARK: - Lexical rules

/// What a language treats as a comment or string, so brackets inside them
/// are ignored. Deliberately small: enough to keep `"{"` and `// }` from
/// producing phantom pairs, not a parser.
struct LexicalRules: Sendable, Equatable {
    var lineComment: [UInt16] = []
    var blockOpen: [UInt16] = []
    var blockClose: [UInt16] = []
    var quotes: Set<UInt16> = []
    /// Quotes that may span lines (JS template literals, Go raw strings).
    var multilineQuotes: Set<UInt16> = []
    /// `"""` / `'''` open a multi-line string (Python, Swift).
    var tripleQuotes: Bool = false
    /// `'x'` is a character literal rather than a string (Rust, Go): skipped
    /// only when it really is one, so Rust lifetimes (`'a`) stay code.
    var charLiteralQuote: Bool = false

    private static func u(_ s: String) -> [UInt16] { Array(s.utf16) }
    private static let dq: UInt16 = 0x22, sq: UInt16 = 0x27, bt: UInt16 = 0x60

    /// Rules for languages that fold by brackets; nil means "no bracket
    /// structure worth folding on, use indentation".
    static func rules(for language: Language) -> LexicalRules? {
        switch language {
        case .swift:
            return LexicalRules(lineComment: u("//"), blockOpen: u("/*"), blockClose: u("*/"),
                                quotes: [dq], tripleQuotes: true)
        case .typescript, .javascript, .ds:
            return LexicalRules(lineComment: u("//"), blockOpen: u("/*"), blockClose: u("*/"),
                                quotes: [dq, sq, bt], multilineQuotes: [bt])
        case .rust:
            return LexicalRules(lineComment: u("//"), blockOpen: u("/*"), blockClose: u("*/"),
                                quotes: [dq, sq], charLiteralQuote: true)
        case .go:
            return LexicalRules(lineComment: u("//"), blockOpen: u("/*"), blockClose: u("*/"),
                                quotes: [dq, bt, sq], multilineQuotes: [bt], charLiteralQuote: true)
        case .json:
            return LexicalRules(lineComment: u("//"), blockOpen: u("/*"), blockClose: u("*/"), quotes: [dq])
        case .css:
            return LexicalRules(blockOpen: u("/*"), blockClose: u("*/"), quotes: [dq, sq])
        case .python, .html, .isml, .markdown, .image, .plaintext:
            return nil
        }
    }

    /// Rules for bracket pairing (colourisation, Go to Matching Bracket).
    /// Python has brackets worth pairing even though it folds by indent.
    static func bracketRules(for language: Language) -> LexicalRules? {
        if language == .python {
            return LexicalRules(lineComment: u("#"), quotes: [dq, sq], tripleQuotes: true)
        }
        return rules(for: language)
    }
}

// MARK: - Lexical scan

struct BracketToken: Sendable, Equatable {
    var index: Int      // UTF-16 offset
    var char: UInt16
}

struct BlockCommentSpan: Sendable, Equatable {
    var start: Int      // offset of the first char of the opener
    var end: Int        // offset of the last char of the closer
}

struct LexicalScan: Sendable, Equatable {
    var brackets: [BracketToken] = []
    var blockComments: [BlockCommentSpan] = []
}

enum LexicalScanner {
    static func isOpen(_ c: UInt16) -> Bool { c == 0x7B || c == 0x5B || c == 0x28 }
    static func isClose(_ c: UInt16) -> Bool { c == 0x7D || c == 0x5D || c == 0x29 }
    static func partner(of c: UInt16) -> UInt16 {
        switch c {
        case 0x7B: return 0x7D
        case 0x5B: return 0x5D
        case 0x28: return 0x29
        case 0x7D: return 0x7B
        case 0x5D: return 0x5B
        default:   return 0x28
        }
    }

    /// Collects `{}[]()` that are real code (outside strings and comments)
    /// and the extent of each block comment.
    static func scan(_ u: [UInt16], rules: LexicalRules) -> LexicalScan {
        var result = LexicalScan()
        let n = u.count
        var i = 0
        func matches(_ token: [UInt16], at p: Int) -> Bool {
            guard !token.isEmpty, p + token.count <= n else { return false }
            for k in 0..<token.count where u[p + k] != token[k] { return false }
            return true
        }
        while i < n {
            let c = u[i]
            if matches(rules.lineComment, at: i) {
                while i < n && u[i] != 0x0A { i += 1 }
                continue
            }
            if matches(rules.blockOpen, at: i) {
                let start = i
                i += rules.blockOpen.count
                while i < n && !matches(rules.blockClose, at: i) { i += 1 }
                let end = min(n - 1, i + rules.blockClose.count - 1)
                i = min(n, i + rules.blockClose.count)
                result.blockComments.append(BlockCommentSpan(start: start, end: end))
                continue
            }
            if rules.quotes.contains(c) {
                if c == 0x27 && rules.charLiteralQuote {
                    if i + 2 < n && u[i + 2] == 0x27 && u[i + 1] != 0x5C { i += 3; continue }
                    if i + 3 < n && u[i + 1] == 0x5C && u[i + 3] == 0x27 { i += 4; continue }
                    i += 1
                    continue
                }
                if rules.tripleQuotes, i + 2 < n, u[i + 1] == c, u[i + 2] == c {
                    i += 3
                    while i < n && !(i + 2 < n && u[i] == c && u[i + 1] == c && u[i + 2] == c) {
                        if u[i] == 0x5C { i += 1 }
                        i += 1
                    }
                    i = min(n, i + 3)
                    continue
                }
                let multiline = rules.multilineQuotes.contains(c)
                i += 1
                while i < n {
                    let d = u[i]
                    if d == 0x5C { i += 2; continue }
                    if d == c { i += 1; break }
                    if d == 0x0A && !multiline { break }
                    i += 1
                }
                continue
            }
            if isOpen(c) || isClose(c) { result.brackets.append(BracketToken(index: i, char: c)) }
            i += 1
        }
        return result
    }
}

// MARK: - Bracket pairing

struct BracketPair: Sendable, Equatable {
    var open: Int
    var close: Int
    var depth: Int     // 0-based nesting depth of the opener
}

struct BracketPairing: Sendable, Equatable {
    var pairs: [BracketPair] = []
    var unmatched: [Int] = []
}

enum BracketScanner {
    /// Pairs openers with closers by kind using a stack. A closer that does
    /// not match the innermost opener is reported unmatched without popping,
    /// so one stray `)` does not wreck every pair after it.
    static func pair(_ tokens: [BracketToken]) -> BracketPairing {
        var out = BracketPairing()
        var stack: [BracketToken] = []
        for t in tokens {
            if LexicalScanner.isOpen(t.char) {
                stack.append(t)
            } else if let top = stack.last, LexicalScanner.partner(of: top.char) == t.char {
                stack.removeLast()
                out.pairs.append(BracketPair(open: top.index, close: t.index, depth: stack.count))
            } else {
                out.unmatched.append(t.index)
            }
        }
        out.unmatched.append(contentsOf: stack.map(\.index))
        out.unmatched.sort()
        out.pairs.sort { $0.open < $1.open }
        return out
    }

    static func pairing(for text: String, language: Language) -> BracketPairing {
        guard let rules = LexicalRules.bracketRules(for: language) else { return BracketPairing() }
        return pair(LexicalScanner.scan(Array(text.utf16), rules: rules).brackets)
    }

    /// Where Go to Matching Bracket should put the caret. A bracket touching
    /// the caret (the one after it first, then the one before) jumps to its
    /// partner: just after a closer, or onto an opener. With no bracket
    /// touching, it jumps to the closer of the innermost enclosing pair.
    static func jumpTarget(pairs: [BracketPair], caret: Int) -> Int? {
        for idx in [caret, caret - 1] where idx >= 0 {
            if let p = pairs.first(where: { $0.open == idx }) { return p.close + 1 }
            if let p = pairs.first(where: { $0.close == idx }) { return p.open }
        }
        let enclosing = pairs.filter { $0.open < caret && caret <= $0.close }
        if let inner = enclosing.max(by: { $0.open < $1.open }) { return inner.close }
        return nil
    }
}

// MARK: - Fold ranges

enum FoldingRangeComputer {

    static func lineStarts(_ u: [UInt16]) -> [Int] {
        var starts = [0]
        for (i, c) in u.enumerated() where c == 0x0A { starts.append(i + 1) }
        return starts
    }

    private static func line(of index: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Index of the first non-blank character of `line`, or nil when blank.
    private static func firstNonBlank(_ u: [UInt16], starts: [Int], line: Int) -> Int? {
        var i = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] : u.count
        while i < end {
            let c = u[i]
            if c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D { return i }
            i += 1
        }
        return nil
    }

    static func compute(text: String, language: Language, tabSize: Int = 4) -> [FoldRange] {
        let u = Array(text.utf16)
        let starts = lineStarts(u)
        guard starts.count > 1 else { return [] }
        var out: [FoldRange] = []
        if let rules = LexicalRules.rules(for: language) {
            let scan = LexicalScanner.scan(u, rules: rules)
            for p in BracketScanner.pair(scan.brackets).pairs {
                let s = line(of: p.open, in: starts), c = line(of: p.close, in: starts)
                guard c > s else { continue }
                let closerLeads = firstNonBlank(u, starts: starts, line: c) == p.close
                let e = closerLeads ? c - 1 : c
                if e > s { out.append(FoldRange(startLine: s, endLine: e)) }
            }
            for b in scan.blockComments {
                let s = line(of: b.start, in: starts), e = line(of: b.end, in: starts)
                if e > s { out.append(FoldRange(startLine: s, endLine: e)) }
            }
        } else {
            out = indentationRanges(u, starts: starts, tabSize: max(1, tabSize))
        }
        return finalize(out, lineCount: starts.count)
    }

    private static func indentationRanges(_ u: [UInt16], starts: [Int], tabSize: Int) -> [FoldRange] {
        var result: [FoldRange] = []
        var stack: [(line: Int, indent: Int)] = []
        var lastNonBlank = -1
        func close(upTo indent: Int?) {
            while let top = stack.last, indent.map({ top.indent >= $0 }) ?? true {
                stack.removeLast()
                if lastNonBlank > top.line { result.append(FoldRange(startLine: top.line, endLine: lastNonBlank)) }
            }
        }
        for l in 0..<starts.count {
            guard let first = firstNonBlank(u, starts: starts, line: l) else { continue }
            var width = 0
            var k = starts[l]
            while k < first { width += u[k] == 0x09 ? tabSize : 1; k += 1 }
            close(upTo: width)
            stack.append((l, width))
            lastNonBlank = l
        }
        close(upTo: nil)
        return result
    }

    /// Drops empty or out-of-range spans, keeps the widest span per start
    /// line, and sorts by start line (outer before inner).
    static func finalize(_ ranges: [FoldRange], lineCount: Int) -> [FoldRange] {
        var best: [Int: Int] = [:]
        for r in ranges where r.startLine >= 0 && r.endLine > r.startLine && r.startLine < lineCount {
            let e = min(r.endLine, lineCount - 1)
            if e > r.startLine { best[r.startLine] = max(best[r.startLine] ?? 0, e) }
        }
        return best.keys.sorted().map { FoldRange(startLine: $0, endLine: best[$0] ?? $0) }
    }

    /// Adapts server ranges, which include the closing-bracket line, to this
    /// editor's convention of leaving a trailing `}` visible.
    static func normalize(lsp: [FoldRange], text: String) -> [FoldRange] {
        let u = Array(text.utf16)
        let starts = lineStarts(u)
        let adjusted: [FoldRange] = lsp.map { r in
            guard r.endLine > r.startLine, r.endLine < starts.count,
                  let first = firstNonBlank(u, starts: starts, line: r.endLine),
                  LexicalScanner.isClose(u[first]) else { return r }
            return FoldRange(startLine: r.startLine, endLine: r.endLine - 1)
        }
        return finalize(adjusted, lineCount: starts.count)
    }

    /// 1-based nesting depth of each range in `ranges` (which must be sorted
    /// by start line, as `finalize` returns them).
    static func depths(of ranges: [FoldRange]) -> [Int] {
        var stackEnds: [Int] = []
        return ranges.map { r in
            while let top = stackEnds.last, top < r.startLine { stackEnds.removeLast() }
            stackEnds.append(r.endLine)
            return stackEnds.count
        }
    }
}
