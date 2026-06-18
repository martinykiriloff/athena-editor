// SyntaxHighlighter.swift
// Athena — regex-based syntax highlighting for the NSTextView editor.
// Swift 6, strict concurrency.

import AppKit
import Foundation

// MARK: - SyntaxRule

struct SyntaxRule {
    var pattern: NSRegularExpression
    var color: NSColor
    /// Capture group index whose range is coloured; 0 means the whole match.
    var group: Int = 0
}

// MARK: - SyntaxHighlighter

final class SyntaxHighlighter {

    // MARK: Properties

    private let language: Language
    private let theme: EditorTheme
    private let rules: [SyntaxRule]

    // MARK: Properties

    private let fontSize:      CGFloat
    private let fontFamily:    String
    private let fontLigatures: Bool
    private let lineHeight:    CGFloat

    // MARK: Init

    init(language: Language,
         theme: EditorTheme = .darcula,
         fontSize: CGFloat = 14,
         fontFamily: String = "JetBrains Mono",
         fontLigatures: Bool = true,
         lineHeight: CGFloat = 1.5) {
        self.language      = language
        self.theme         = theme
        self.fontSize      = fontSize
        self.fontFamily    = fontFamily
        self.fontLigatures = fontLigatures
        self.lineHeight    = lineHeight
        self.rules = SyntaxHighlighter.buildRules(for: language, theme: theme)
    }

    // MARK: Font

    func makeFont() -> NSFont {
        NSFont(name: fontFamily, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    // MARK: Public API

    func highlight(_ text: String) -> NSAttributedString {
        let font = makeFont()
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight

        var baseAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.foreground,
            .font: font,
            .paragraphStyle: para,
        ]
        if fontLigatures { baseAttrs[.ligature] = 2 }

        let result = NSMutableAttributedString(string: text, attributes: baseAttrs)

        let fullRange = NSRange(text.startIndex..., in: text)

        // Apply each rule in order; comment rules are appended last so they
        // override any keyword colouring that fell inside a comment.
        for rule in rules {
            rule.pattern.enumerateMatches(
                in: text,
                options: [],
                range: fullRange
            ) { match, _, _ in
                guard let match else { return }
                let range: NSRange
                if rule.group > 0 && rule.group < match.numberOfRanges {
                    range = match.range(at: rule.group)
                } else {
                    range = match.range
                }
                guard range.location != NSNotFound else { return }
                result.addAttribute(.foregroundColor, value: rule.color, range: range)
            }
        }

        return result
    }

    // MARK: Rule building

    // swiftlint:disable function_body_length
    private static func buildRules(for language: Language, theme: EditorTheme) -> [SyntaxRule] {
        var rules: [SyntaxRule] = []

        func add(_ pattern: String, color: NSColor, group: Int = 0) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            rules.append(SyntaxRule(pattern: regex, color: color, group: group))
        }

        let kw  = theme.keyword
        let str = theme.string
        let num = theme.number
        let cmt = theme.comment
        let typ = theme.type
        let fn  = theme.function

        switch language {

        // --------------------------------------------------------------------
        case .swift:
            let swiftKeywords = [
                "var", "let", "func", "class", "struct", "enum", "protocol",
                "extension", "import", "return", "if", "else", "guard", "for",
                "while", "switch", "case", "default", "break", "continue",
                "throw", "throws", "try", "catch", "async", "await", "actor",
                "nonisolated", "public", "private", "internal", "fileprivate",
                "open", "static", "final", "override", "init", "deinit",
                "self", "super", "true", "false", "nil", "in", "is", "as",
                "where", "typealias", "associatedtype", "some", "any",
                "mutating", "lazy", "weak", "unowned", "inout", "defer"
            ]
            add("\\b(\(swiftKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add("\\b([A-Z][A-Za-z0-9_]*)\\b", color: typ, group: 1)
            add("\\b([a-z_][A-Za-z0-9_]*)(?=\\s*\\()", color: fn, group: 1)
            add("\"(?:[^\"\\\\]|\\\\.)*\"", color: str)
            add("\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", color: num)
            add("//[^\\n]*", color: cmt)
            add("/\\*[\\s\\S]*?\\*/", color: cmt)

        // --------------------------------------------------------------------
        case .typescript, .javascript:
            let tsKeywords = [
                "var", "let", "const", "function", "class", "interface",
                "type", "enum", "namespace", "module", "import", "export",
                "from", "default", "return", "if", "else", "for", "while",
                "do", "switch", "case", "break", "continue", "throw", "try",
                "catch", "finally", "new", "delete", "typeof", "instanceof",
                "in", "of", "async", "await", "yield", "extends", "implements",
                "super", "this", "true", "false", "null", "undefined", "void",
                "never", "any", "unknown", "readonly", "static", "public",
                "private", "protected", "abstract", "override", "declare",
                "keyof", "infer", "as", "is", "satisfies"
            ]
            add("\\b(\(tsKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add("\\b([A-Z][A-Za-z0-9_]*)\\b", color: typ, group: 1)
            add("\\b([a-z_][A-Za-z0-9_]*)(?=\\s*\\()", color: fn, group: 1)
            add("`(?:[^`\\\\]|\\\\.)*`", color: str)
            add("\"(?:[^\"\\\\]|\\\\.)*\"", color: str)
            add("'(?:[^'\\\\]|\\\\.)*'", color: str)
            add("\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?n?\\b", color: num)
            add("//[^\\n]*", color: cmt)
            add("/\\*[\\s\\S]*?\\*/", color: cmt)

        // --------------------------------------------------------------------
        case .python:
            let pyKeywords = [
                "def", "class", "import", "from", "return", "if", "elif",
                "else", "for", "while", "try", "except", "finally", "with",
                "as", "pass", "lambda", "yield", "not", "and", "or", "in",
                "is", "None", "True", "False", "async", "await", "raise",
                "del", "global", "nonlocal", "assert", "break", "continue"
            ]
            add("\\b(\(pyKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add("\\b([A-Z][A-Za-z0-9_]*)\\b", color: typ, group: 1)
            add("\\b([a-z_][A-Za-z0-9_]*)(?=\\s*\\()", color: fn, group: 1)
            add("\"\"\"[\\s\\S]*?\"\"\"", color: str)
            add("'''[\\s\\S]*?'''", color: str)
            add("\"(?:[^\"\\\\]|\\\\.)*\"", color: str)
            add("'(?:[^'\\\\]|\\\\.)*'", color: str)
            add("\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?[jJ]?\\b", color: num)
            add("#[^\\n]*", color: cmt)

        // --------------------------------------------------------------------
        case .rust:
            let rustKeywords = [
                "fn", "let", "mut", "const", "static", "struct", "enum",
                "trait", "impl", "use", "mod", "pub", "crate", "super",
                "self", "Self", "return", "if", "else", "match", "for",
                "while", "loop", "break", "continue", "async", "await",
                "move", "ref", "in", "where", "type", "true", "false",
                "as", "dyn", "extern", "unsafe", "box"
            ]
            add("\\b(\(rustKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add("\\b([A-Z][A-Za-z0-9_]*)\\b", color: typ, group: 1)
            add("\\b([a-z_][a-z0-9_]*)(?=\\s*\\()", color: fn, group: 1)
            add("\"(?:[^\"\\\\]|\\\\.)*\"", color: str)
            add("\\b\\d+(?:\\.\\d+)?(?:[uif](?:8|16|32|64|128|size))?\\b", color: num)
            add("//[^\\n]*", color: cmt)
            add("/\\*[\\s\\S]*?\\*/", color: cmt)

        // --------------------------------------------------------------------
        case .go:
            let goKeywords = [
                "func", "var", "const", "type", "struct", "interface",
                "package", "import", "return", "if", "else", "for", "range",
                "switch", "case", "default", "break", "continue", "goto",
                "go", "chan", "select", "defer", "map", "true", "false",
                "nil", "make", "new", "len", "cap", "append", "copy",
                "delete", "close", "panic", "recover", "error"
            ]
            add("\\b(\(goKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add("\\b([A-Z][A-Za-z0-9_]*)\\b", color: typ, group: 1)
            add("\\b([a-z_][A-Za-z0-9_]*)(?=\\s*\\()", color: fn, group: 1)
            add("\"(?:[^\"\\\\]|\\\\.)*\"", color: str)
            add("`[^`]*`", color: str)
            add("\\b\\d+(?:\\.\\d+)?\\b", color: num)
            add("//[^\\n]*", color: cmt)
            add("/\\*[\\s\\S]*?\\*/", color: cmt)

        // --------------------------------------------------------------------
        case .json:
            add("\"([^\"\\\\]|\\\\.)*\"(?=\\s*:)", color: fn)
            add("(?<=:\\s*)\"(?:[^\"\\\\]|\\\\.)*\"", color: str)
            add("\\b(true|false|null)\\b", color: kw, group: 1)
            add("-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", color: num)

        // --------------------------------------------------------------------
        case .css:
            add("[.#]?[a-zA-Z][a-zA-Z0-9_-]*(?=\\s*\\{)", color: fn)
            add("\\b([a-z][a-z-]*)(?=\\s*:)", color: typ, group: 1)
            add(":\\s*([^;{}\\n]+)", color: str, group: 1)
            add("\\b\\d+(?:\\.\\d+)?(?:px|em|rem|vh|vw|%|s|ms)?\\b", color: num)
            add("@[a-zA-Z][a-zA-Z-]*", color: kw)
            add("//[^\\n]*", color: cmt)
            add("/\\*[\\s\\S]*?\\*/", color: cmt)

        // --------------------------------------------------------------------
        case .html:
            add("</?([a-zA-Z][a-zA-Z0-9]*)(?=[\\s/>]|$)", color: kw, group: 1)
            add("\\b([a-zA-Z][a-zA-Z0-9_-]*)(?=\\s*=)", color: typ, group: 1)
            add("\"(?:[^\"\\\\]|\\\\.)*\"", color: str)
            add("'(?:[^'\\\\]|\\\\.)*'", color: str)
            add("<!--[\\s\\S]*?-->", color: cmt)
            add("<!DOCTYPE[^>]*>", color: cmt)

        // --------------------------------------------------------------------
        case .markdown:
            add("^#{1,6}[^\\n]*", color: kw)
            add("\\*\\*[^*]+\\*\\*", color: typ)
            add("\\*[^*]+\\*", color: fn)
            add("`[^`]+`", color: str)
            add("```[\\s\\S]*?```", color: cmt)
            add("\\[[^\\]]+\\]\\([^)]+\\)", color: fn)

        // --------------------------------------------------------------------
        case .plaintext:
            break
        }

        return rules
    }
    // swiftlint:enable function_body_length
}
