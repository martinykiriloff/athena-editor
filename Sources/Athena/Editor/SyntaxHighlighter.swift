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

private extension String {
    /// Makes `^` / `$` match at line boundaries (the highlighter compiles
    /// patterns without `.anchorsMatchLines`).
    var inlineMultiline: String { "(?m)" + self }
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
         theme: EditorTheme = .athenaDracula,
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

    // MARK: Incremental API

    /// Attributes every character gets before token colours are layered on.
    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight

        var baseAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.foreground,
            .font: makeFont(),
            .paragraphStyle: para,
        ]
        if fontLigatures { baseAttrs[.ligature] = 2 }
        return baseAttrs
    }

    /// The default (un-highlighted) text colour — what a character carries
    /// when no rule matched it.
    var baseForeground: NSColor { theme.foreground }

    /// Token colour spans for `range` of `text`, in rule order (later spans
    /// override earlier ones when applied in sequence). Regexes run with
    /// transparent, non-anchoring bounds so lookbehind/lookahead and `^`
    /// behave exactly as they do in a whole-document pass.
    func spans(in text: String, range: NSRange) -> [(range: NSRange, color: NSColor)] {
        var out: [(range: NSRange, color: NSColor)] = []
        for rule in rules {
            rule.pattern.enumerateMatches(
                in: text,
                options: [.withTransparentBounds, .withoutAnchoringBounds],
                range: range
            ) { match, _, _ in
                guard let match else { return }
                let r: NSRange
                if rule.group > 0 && rule.group < match.numberOfRanges {
                    r = match.range(at: rule.group)
                } else {
                    r = match.range
                }
                guard r.location != NSNotFound else { return }
                out.append((r, rule.color))
            }
        }
        return out
    }

    /// Re-highlights `range` of `storage` in place: resets the range to the
    /// base attributes, then layers token colours. The storage's characters
    /// are never replaced, so selection and undo are untouched.
    func apply(to storage: NSTextStorage, range: NSRange) {
        let length = storage.length
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard clamped.length > 0 else { return }
        let text = storage.string
        let tokens = spans(in: text, range: clamped)
        storage.beginEditing()
        storage.setAttributes(baseAttributes(), range: clamped)
        for token in tokens {
            storage.addAttribute(.foregroundColor, value: token.color, range: token.range)
        }
        storage.endEditing()
    }

    // MARK: Public API

    func highlight(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes())
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        // Rules are applied in order; comment rules come last so they
        // override any keyword colouring that fell inside a comment.
        for token in spans(in: text, range: fullRange) {
            result.addAttribute(.foregroundColor, value: token.color, range: token.range)
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
            // JSX/TSX tags. Conservative so plain TS generics (`Array<string>`,
            // `foo<T>(x)`) stay untouched: the `<` must not follow an
            // identifier or closing bracket, and a one-letter uppercase name
            // (`<T>`) is treated as a type parameter, not a tag.
            add(#"(?<![\w$)\]])<((?:[A-Za-z][\w.:-]+|[a-z])(?=[\s/>]))"#, color: kw, group: 1)
            // `</` can't start anything else, so closing tags need no lookbehind.
            add(#"</((?:[A-Za-z][\w.:-]+|[a-z])(?=>))"#, color: kw, group: 1)
            add(#"(?<![\w$)\]])</?>"#, color: kw)
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
        // ISML — Salesforce Commerce Cloud template language (HTML superset).
        // ISML tags (<isif>, <isloop>, <isprint> …) get keyword colour;
        // standard HTML tags get function colour; ${expr} gets string colour.
        case .isml:
            // Standard HTML tags (function colour, applied first)
            add("</?([a-zA-Z][a-zA-Z0-9]*)(?=[\\s/>]|$)", color: fn, group: 1)
            // ISML tags override with keyword colour
            add("</?+(is[a-zA-Z]+)(?=[\\s/>]|$)", color: kw, group: 1)
            // HTML / tag attributes
            add("\\b([a-zA-Z][a-zA-Z0-9_-]*)(?=\\s*=)", color: typ, group: 1)
            // SFCC pipeline / expression ${...}
            add("\\$\\{[^}]*\\}", color: str)
            // Quoted attribute values and strings
            add("\"(?:[^\"\\\\]|\\\\.)*\"", color: str)
            add("'(?:[^'\\\\]|\\\\.)*'", color: str)
            // Standard HTML comment (before ISML comment so triple-dash wins)
            add("<!--[\\s\\S]*?-->", color: cmt)
            // ISML triple-dash comment <!--- ... ---> (applied last → overrides)
            add("<!---[\\s\\S]*?--->", color: cmt)
            add("<!DOCTYPE[^>]*>", color: cmt)

        // --------------------------------------------------------------------
        // DS — Demandware Script (ECMAScript 3 + SFCC extensions).
        // Treated as JavaScript with extra SFCC-specific keywords.
        case .ds:
            let dsKeywords = [
                "var", "function", "return", "if", "else", "for", "while",
                "do", "switch", "case", "break", "continue", "throw", "try",
                "catch", "finally", "new", "delete", "typeof", "instanceof",
                "in", "this", "true", "false", "null", "undefined", "void",
                "with", "default",
                // SFCC additions
                "importPackage", "importClass", "require"
            ]
            add("\\b(\(dsKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add("\\b([A-Z][A-Za-z0-9_]*)\\b", color: typ, group: 1)
            add("\\b([a-z_][A-Za-z0-9_]*)(?=\\s*\\()", color: fn, group: 1)
            // Highlight dw.* package paths
            add("\\bdw(?:\\.[a-zA-Z]+)+\\b", color: typ)
            add("\"(?:[^\"\\\\]|\\\\.)*\"", color: str)
            add("'(?:[^'\\\\]|\\\\.)*'", color: str)
            add("\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", color: num)
            add("//[^\\n]*", color: cmt)
            add("/\\*[\\s\\S]*?\\*/", color: cmt)

        // --------------------------------------------------------------------
        case .markdown:
            add("^#{1,6}[^\\n]*", color: kw)
            add("\\*\\*[^*]+\\*\\*", color: typ)
            add("\\*[^*]+\\*", color: fn)
            add("`[^`]+`", color: str)
            add("```[\\s\\S]*?```", color: cmt)
            add("\\[[^\\]]+\\]\\([^)]+\\)", color: fn)

        // --------------------------------------------------------------------
        // Image tabs render `ImagePreviewView` instead of the text editor, so
        // this highlighter never actually runs against one in practice — a
        // no-op case is here only to keep the switch exhaustive.
        case .yaml:
            add(#"^\s*(?:-\s+)?([\w./-]+|"[^"\n]*"|'[^'\n]*')(?=\s*:(?:\s|$))"#.inlineMultiline, color: typ, group: 1)
            add(#"[&*][\w-]+"#, color: fn)
            add(#"(?<![\w.-])(?:true|false|yes|no|on|off|null|~)(?![\w.-])"#, color: kw)
            add(#"(?<![\w.-])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?![\w.-])"#, color: num)
            add(#"^---|^\.\.\."#.inlineMultiline, color: kw)
            add(#""(?:[^"\\\n]|\\.)*""#, color: str)
            add(#"'(?:[^'\n]|'')*'"#, color: str)
            add(#"(?<![^\s])#[^\n]*"#, color: cmt)

        // --------------------------------------------------------------------
        case .sql:
            let sqlKeywords = [
                "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                "create", "alter", "drop", "table", "index", "view", "database", "schema", "join",
                "inner", "left", "right", "full", "outer", "cross", "on", "as", "and", "or", "not",
                "null", "is", "in", "like", "between", "exists", "group", "by", "order", "having",
                "limit", "offset", "union", "all", "distinct", "case", "when", "then", "else", "end",
                "primary", "key", "foreign", "references", "constraint", "default", "unique",
                "check", "begin", "commit", "rollback", "transaction", "with", "returning",
                "asc", "desc", "true", "false", "if", "cascade", "add", "column"
            ]
            add("(?i)\\b(\(sqlKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add(#"(?i)\b(int|integer|bigint|smallint|serial|bigserial|varchar|char|text|boolean|bool|date|timestamp|timestamptz|numeric|decimal|float|double|real|uuid|json|jsonb|blob)\b"#, color: typ, group: 1)
            add(#"\b([A-Za-z_][A-Za-z0-9_]*)(?=\s*\()"#, color: fn, group: 1)
            add(#"\b\d+(?:\.\d+)?\b"#, color: num)
            add(#""(?:[^"]|"")*""#, color: str)
            add(#"'(?:[^']|'')*'"#, color: str)
            add(#"--[^\n]*"#, color: cmt)
            add(#"/\*[\s\S]*?\*/"#, color: cmt)

        // --------------------------------------------------------------------
        case .shell:
            let shKeywords = [
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
                "esac", "in", "function", "select", "return", "exit", "break", "continue",
                "local", "export", "readonly", "declare", "unset", "source", "alias", "set",
                "shift", "trap", "eval", "exec", "time"
            ]
            add("(?<![\\w-])(\(shKeywords.joined(separator: "|")))(?![\\w-])", color: kw, group: 1)
            add(#"(?<![\w-])(echo|cd|ls|cat|grep|sed|awk|rm|cp|mv|mkdir|chmod|chown|curl|git|make|test|printf|read|touch|find|xargs)(?![\w-])"#, color: fn, group: 1)
            add(#"\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])"#, color: typ)
            add(#"(?<![\w$])\b\d+\b"#, color: num)
            add(#"^\s*([A-Za-z_][A-Za-z0-9_]*)(?==)"#.inlineMultiline, color: typ, group: 1)
            add(#""(?:[^"\\]|\\[\s\S])*""#, color: str)
            add(#"'[^']*'"#, color: str)
            add(#"<<-?\s*(["']?)(\w+)\1[^\n]*\n[\s\S]*?^[ \t]*\2[ \t]*$"#.inlineMultiline, color: str)
            add(#"(?<![^\s;|&])#[^\n]*"#, color: cmt)

        // --------------------------------------------------------------------
        case .php:
            let phpKeywords = [
                "function", "class", "interface", "trait", "extends", "implements", "namespace",
                "use", "return", "if", "else", "elseif", "foreach", "for", "while", "do", "switch",
                "case", "default", "break", "continue", "try", "catch", "finally", "throw", "new",
                "public", "private", "protected", "static", "abstract", "final", "const", "echo",
                "print", "isset", "unset", "empty", "true", "false", "null", "as", "instanceof",
                "match", "fn", "readonly", "enum", "require", "require_once", "include",
                "include_once", "global", "self", "parent"
            ]
            add("\\b(\(phpKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add(#"\b([A-Z][A-Za-z0-9_]*)\b"#, color: typ, group: 1)
            add(#"\b([A-Za-z_][A-Za-z0-9_]*)(?=\s*\()"#, color: fn, group: 1)
            add(#"<\?php|<\?=|\?>"#, color: kw)
            add(#"\$[A-Za-z_][A-Za-z0-9_]*"#, color: typ)
            add(#"\b\d+(?:\.\d+)?\b"#, color: num)
            add(#""(?:[^"\\]|\\[\s\S])*""#, color: str)
            add(#"'(?:[^'\\]|\\[\s\S])*'"#, color: str)
            add(#"<<<\s*(["']?)(\w+)\1[^\n]*\n[\s\S]*?^[ \t]*\2\b"#.inlineMultiline, color: str)
            add(#"//[^\n]*"#, color: cmt)
            add(#"(?<![\w$])#(?!\[)[^\n]*"#, color: cmt)
            add(#"/\*[\s\S]*?\*/"#, color: cmt)

        // --------------------------------------------------------------------
        case .java, .kotlin, .c, .cpp:
            let words: [String]
            switch language {
            case .java:
                words = ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
                         "class", "const", "continue", "default", "do", "double", "else", "enum",
                         "extends", "final", "finally", "float", "for", "if", "implements", "import",
                         "instanceof", "int", "interface", "long", "new", "package", "private",
                         "protected", "public", "return", "short", "static", "super", "switch",
                         "synchronized", "this", "throw", "throws", "try", "void", "volatile",
                         "while", "var", "record", "true", "false", "null"]
            case .kotlin:
                words = ["fun", "val", "var", "class", "object", "interface", "package", "import",
                         "return", "if", "else", "when", "for", "while", "do", "break", "continue",
                         "try", "catch", "finally", "throw", "is", "in", "as", "this", "super",
                         "null", "true", "false", "override", "open", "abstract", "sealed", "data",
                         "enum", "companion", "private", "public", "protected", "internal",
                         "suspend", "inline", "lateinit", "const", "typealias", "by", "init"]
            case .c:
                words = ["auto", "break", "case", "char", "const", "continue", "default", "do",
                         "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
                         "int", "long", "register", "return", "short", "signed", "sizeof", "static",
                         "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
                         "while", "NULL", "true", "false"]
            default:
                words = ["auto", "break", "case", "catch", "char", "class", "const", "constexpr",
                         "continue", "default", "delete", "do", "double", "else", "enum", "explicit",
                         "extern", "float", "for", "friend", "if", "inline", "int", "long",
                         "namespace", "new", "noexcept", "nullptr", "operator", "private",
                         "protected", "public", "return", "short", "signed", "sizeof", "static",
                         "struct", "switch", "template", "this", "throw", "try", "typedef",
                         "typename", "union", "unsigned", "using", "virtual", "void", "volatile",
                         "while", "override", "final", "true", "false"]
            }
            add("\\b(\(words.joined(separator: "|")))\\b", color: kw, group: 1)
            add(#"\b([A-Z][A-Za-z0-9_]*)\b"#, color: typ, group: 1)
            add(#"\b([A-Za-z_][A-Za-z0-9_]*)(?=\s*\()"#, color: fn, group: 1)
            add(#"@[A-Za-z_][A-Za-z0-9_.]*"#, color: typ)
            if language == .c || language == .cpp {
                add(#"^\s*#\s*[a-z]+"#.inlineMultiline, color: kw)
            }
            add(#"\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)[uUlLfF]*\b"#, color: num)
            add(#""(?:[^"\\\n]|\\.)*""#, color: str)
            add(#"'(?:[^'\\\n]|\\.)+'"#, color: str)
            if language == .java || language == .kotlin {
                add("\"\"\"[\\s\\S]*?\"\"\"", color: str)
            }
            if language == .cpp {
                add(#"R"([^()\s]*)\([\s\S]*?\)\1""#, color: str)
            }
            add(#"//[^\n]*"#, color: cmt)
            add(#"/\*[\s\S]*?\*/"#, color: cmt)

        // --------------------------------------------------------------------
        case .ruby:
            let rbKeywords = [
                "def", "class", "module", "end", "if", "elsif", "else", "unless", "case", "when",
                "while", "until", "for", "in", "do", "begin", "rescue", "ensure", "raise",
                "return", "yield", "break", "next", "redo", "retry", "self", "super", "nil",
                "true", "false", "and", "or", "not", "then", "require", "require_relative",
                "include", "extend", "attr_accessor", "attr_reader", "attr_writer", "private",
                "public", "protected", "lambda", "proc", "alias", "defined?"
            ]
            add("\\b(\(rbKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add(#"\b([A-Z][A-Za-z0-9_]*)\b"#, color: typ, group: 1)
            add(#"\b([a-z_][A-Za-z0-9_]*[?!]?)(?=\s*\()"#, color: fn, group: 1)
            add(#"(?<![:\w]):[A-Za-z_][A-Za-z0-9_]*[?!]?"#, color: num)
            add(#"@@?[A-Za-z_][A-Za-z0-9_]*|\$[A-Za-z_][A-Za-z0-9_]*"#, color: typ)
            add(#"\b\d+(?:\.\d+)?\b"#, color: num)
            add(#""(?:[^"\\]|\\[\s\S])*""#, color: str)
            add(#"'(?:[^'\\]|\\[\s\S])*'"#, color: str)
            add(#"<<[~-]?(["']?)([A-Z_]+)\1[^\n]*\n[\s\S]*?^[ \t]*\2$"#.inlineMultiline, color: str)
            add(#"#[^\n]*"#, color: cmt)
            add(#"^=begin[\s\S]*?^=end"#.inlineMultiline, color: cmt)

        // --------------------------------------------------------------------
        // Vue / Svelte single-file components: HTML tags and attributes,
        // directives, `{{ }}` / `{ }` expressions, plus a few distinctive
        // script keywords. Embedded <script>/<style> bodies are not parsed
        // as separate languages (regex highlighter, one rule set per file).
        case .vue, .svelte:
            add(#"\b(import|export|const|let|function|return|await|defineProps|defineEmits)\b"#, color: kw, group: 1)
            add(#"</?([a-zA-Z][a-zA-Z0-9.-]*)(?=[\s/>]|$)"#, color: fn, group: 1)
            add(#"\b([a-zA-Z@:#][a-zA-Z0-9_:.@#-]*)(?=\s*=)"#, color: typ, group: 1)
            add(#"(?<=\s)(v-[a-z-]+|:[a-zA-Z-]+|@[a-zA-Z.-]+|#[a-zA-Z-]+|on:[a-z]+|bind:[a-z]+|use:[a-z]+|class:[a-z-]+)"#, color: kw, group: 1)
            if language == .vue {
                add(#"\{\{[\s\S]*?\}\}"#, color: num)
            } else {
                add(#"\{[#:/@](?:if|else|each|await|then|catch|key|html|const|debug|snippet|render)\b[^}\n]*\}"#, color: kw)
            }
            add(#""(?:[^"\\]|\\.)*""#, color: str)
            add(#"'(?:[^'\\]|\\.)*'"#, color: str)
            add(#"<!--[\s\S]*?-->"#, color: cmt)
            add(#"//[^\n]*"#, color: cmt)

        // --------------------------------------------------------------------
        case .toml:
            add(#"^\s*\[\[?[^\]\n]+\]\]?"#.inlineMultiline, color: kw)
            add(#"^\s*([A-Za-z0-9_.-]+|"[^"\n]*")(?=\s*=)"#.inlineMultiline, color: typ, group: 1)
            add(#"\b(?:true|false)\b"#, color: kw)
            add(#"(?<![\w-])[+-]?\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?(?![\w-])"#, color: num)
            add(#""(?:[^"\\\n]|\\.)*""#, color: str)
            add(#"'[^'\n]*'"#, color: str)
            add("\"\"\"[\\s\\S]*?\"\"\"", color: str)
            add(#"'''[\s\S]*?'''"#, color: str)
            add(#"#[^\n]*"#, color: cmt)

        // --------------------------------------------------------------------
        case .graphql:
            let gqlKeywords = [
                "query", "mutation", "subscription", "fragment", "on", "type", "interface", "enum",
                "union", "input", "scalar", "schema", "extend", "directive", "implements",
                "repeatable", "true", "false", "null"
            ]
            add("\\b(\(gqlKeywords.joined(separator: "|")))\\b", color: kw, group: 1)
            add(#"\b([A-Z][A-Za-z0-9_]*)\b"#, color: typ, group: 1)
            add(#"\b([A-Za-z_][A-Za-z0-9_]*)(?=\s*[:(])"#, color: fn, group: 1)
            add(#"[$@][A-Za-z_][A-Za-z0-9_]*"#, color: typ)
            add(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: num)
            add(#""(?:[^"\\\n]|\\.)*""#, color: str)
            add("\"\"\"[\\s\\S]*?\"\"\"", color: str)
            add(#"#[^\n]*"#, color: cmt)

        // --------------------------------------------------------------------
        case .env:
            add(#"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)(?==)"#.inlineMultiline, color: typ, group: 1)
            add(#"^\s*(export)\s+(?=[A-Za-z_])"#.inlineMultiline, color: kw, group: 1)
            add(#"(?<==)[^\n#"']*"#, color: str)
            add(#"\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*)"#, color: fn)
            add(#""(?:[^"\\\n]|\\.)*""#, color: str)
            add(#"'[^'\n]*'"#, color: str)
            add(#"(?:^|(?<=\s))#[^\n]*"#.inlineMultiline, color: cmt)

        // --------------------------------------------------------------------
        case .dockerfile:
            let dockerInstructions = [
                "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
                "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
                "HEALTHCHECK", "SHELL"
            ]
            add("(?i)^\\s*(\(dockerInstructions.joined(separator: "|")))\\b".inlineMultiline, color: kw, group: 1)
            add(#"(?i)\bAS\b(?=\s+\w)"#, color: kw)
            add(#"--[a-z-]+(?==|\b)"#, color: typ)
            add(#"\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*)"#, color: fn)
            add(#"\b\d+(?:\.\d+)?\b"#, color: num)
            add(#""(?:[^"\\\n]|\\.)*""#, color: str)
            add(#"'[^'\n]*'"#, color: str)
            add(#"^\s*#[^\n]*"#.inlineMultiline, color: cmt)

        // --------------------------------------------------------------------
        case .plaintext, .image:
            break
        }

        return rules
    }
    // swiftlint:enable function_body_length
}
