// Emmet.swift
// Athena — compact native Emmet subset (HTML-ish markup + CSS) as a pure type.
// Swift 6, strict concurrency.

import Foundation

// MARK: - EmmetSyntax

enum EmmetSyntax: Sendable, Equatable {
    case markup(MarkupFlavor)
    case css
}

// MARK: - Emmet

/// Expands Emmet abbreviations. Output is an `ExpandedSnippet` (plain text plus
/// `SnippetTabStop`s) so the editor's existing Tab-through-placeholders
/// machinery drives the cursor afterwards.
///
/// Supported markup syntax:
///   - `tag`, `.class`, `#id` (combinable: `div#main.a.b`); `.x` alone means `div`
///   - `>` child, `+` sibling, `^` climb one level (repeatable: `^^`)
///   - `(group)` with `*n`, e.g. `(dt+dd)*2`
///   - `*n` multiply; `$` numbering in names, classes, ids, attributes and text
///     (`$$` zero-pads, `$@-` counts down, `$@3` starts at 3)
///   - `{text}` text content, `[a=b c="d e" flag]` attributes (`flag` → `flag=""`)
///   - implicit tag names from the parent: `ul>li`, `table>tr>td`, `select>option`,
///     inline parents (`p`, `a`, `em`…) → `span`, otherwise `div`
///   - defaults: `a` gets `href`, `img` gets `src`/`alt`, `input` gets `type="text"`,
///     `link` gets `rel`/`href`; void elements self-close per flavor
///   - JSX: `class` → `className`, `for` → `htmlFor`
/// Not supported: `@` filters, `:` snippet aliases (`input:t`), lorem, `!`
/// boilerplate, nested `>` after a group, inline-vs-block line layout (every
/// element gets its own line unless it holds only text).
///
/// Supported CSS syntax: keyword abbreviations (`df`, `jcc`, `aic`, `fdc`, `posa`,
/// `tac`, …), property + values (`m10` → `margin: 10px;`, `p10-20` →
/// `padding: 10px 20px;`, `m-10`, `m10--5`, `w100p`, `w2e`, `h50r`, `ma`→`auto`),
/// unitless properties (`z`, `op`, `fw`, `lh`), and a trailing `!` for `!important`.
enum Emmet {

    struct Result: Sendable, Equatable {
        /// What to replace: the abbreviation text before the caret.
        let range: NSRange
        let snippet: ExpandedSnippet
    }

    // MARK: Entry point

    /// Finds the abbreviation ending at `caret` and expands it, or `nil` when
    /// there is none, it doesn't parse, or the position isn't a sensible place
    /// (inside a tag; outside a CSS block; an unknown word in JSX/Vue/Svelte).
    static func expansion(
        in text: String, caret: Int, syntax: EmmetSyntax, indentUnit: String
    ) -> Result? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        switch syntax {
        case .markup(let flavor):
            guard !isInsideOpenTag(ns, caret: caret) else { return nil }
            guard let (range, abbr) = extractMarkupAbbreviation(ns, caret: caret, lineStart: lineStart) else { return nil }
            guard isPlausible(abbr, flavor: flavor) else { return nil }
            let base = leadingWhitespace(ns, lineStart: lineStart)
            guard let snippet = expandMarkup(abbr, flavor: flavor, indentUnit: indentUnit, baseIndent: base) else { return nil }
            return Result(range: range, snippet: snippet)
        case .css:
            guard isInsideCSSBlock(text, caret: caret) else { return nil }
            guard let (range, abbr) = extractCSSAbbreviation(ns, caret: caret, lineStart: lineStart) else { return nil }
            let prefix = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
                .trimmingCharacters(in: .whitespaces)
            guard prefix.isEmpty || prefix.hasSuffix("{") || prefix.hasSuffix(";") else { return nil }
            guard let snippet = expandCSS(abbr) else { return nil }
            return Result(range: range, snippet: snippet)
        }
    }

    // MARK: - Context

    /// True when `caret` is between an unclosed `<` and the caret (inside a tag).
    static func isInsideOpenTag(_ ns: NSString, caret: Int) -> Bool {
        var i = caret - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x3E { return false }
            if c == 0x3C { return true }
            i -= 1
        }
        return false
    }

    /// True when more `{` than `}` precede `caret` (outside comments/strings).
    static func isInsideCSSBlock(_ text: String, caret: Int) -> Bool {
        let u = Array(text.utf16)
        var depth = 0, i = 0
        let end = min(caret, u.count)
        while i < end {
            let c = u[i]
            if c == 0x2F, i + 1 < end, u[i + 1] == 0x2A {          // /* … */
                i += 2
                while i + 1 < end, !(u[i] == 0x2A && u[i + 1] == 0x2F) { i += 1 }
                if i + 1 >= end { return depth > 0 }
                i += 2; continue
            }
            if c == 0x22 || c == 0x27 {                              // "…" '…'
                i += 1
                while i < end, u[i] != c { i += 1 }
            } else if c == 0x7B { depth += 1 }
            else if c == 0x7D { depth = max(0, depth - 1) }
            i += 1
        }
        return depth > 0
    }

    // MARK: - Extraction

    private static func isIdentChar(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F || c == 0x3A
    }

    private static func leadingWhitespace(_ ns: NSString, lineStart: Int) -> String {
        var i = lineStart
        while i < ns.length, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        return ns.substring(with: NSRange(location: lineStart, length: i - lineStart))
    }

    /// Walks back from the caret over abbreviation characters. Whitespace is
    /// allowed only inside `{}` / `[]`; a `>` that closes an HTML tag
    /// (`<div>`) ends the walk so `<div>ul>li` yields `ul>li`.
    static func extractMarkupAbbreviation(_ ns: NSString, caret: Int, lineStart: Int) -> (NSRange, String)? {
        var i = caret
        var brace = 0, bracket = 0, paren = 0
        while i > lineStart {
            let c = ns.character(at: i - 1)
            if brace > 0 { if c == 0x7B { brace -= 1 }; i -= 1; continue }
            if bracket > 0 { if c == 0x5B { bracket -= 1 }; i -= 1; continue }
            switch c {
            case 0x7D: brace += 1
            case 0x5D: bracket += 1
            case 0x29: paren += 1
            case 0x28: if paren > 0 { paren -= 1 } else { return finish(ns, i, caret) }
            case 0x3E:
                var q = i - 1
                while q > lineStart, isIdentChar(ns.character(at: q - 1)) || ns.character(at: q - 1) == 0x2E { q -= 1 }
                if q > lineStart, ns.character(at: q - 1) == 0x3C { return finish(ns, i, caret) }
                if q > lineStart + 1, ns.character(at: q - 1) == 0x2F, ns.character(at: q - 2) == 0x3C { return finish(ns, i, caret) }
                // `<a href="x">`: a quote before the ">" means a tag's attribute list.
                if q == i - 1, q > lineStart, ns.character(at: q - 1) == 0x22 || ns.character(at: q - 1) == 0x27 {
                    return finish(ns, i, caret)
                }
            default:
                guard isIdentChar(c) || c == 0x2E || c == 0x23 || c == 0x2B || c == 0x5E || c == 0x2A || c == 0x24 || c == 0x40 else {
                    return finish(ns, i, caret)
                }
            }
            i -= 1
        }
        return finish(ns, i, caret, balanced: brace == 0 && bracket == 0 && paren == 0)
    }

    private static func finish(_ ns: NSString, _ start: Int, _ caret: Int, balanced: Bool = true) -> (NSRange, String)? {
        guard balanced else { return nil }
        var s = start
        while s < caret, [0x3E, 0x2B, 0x5E, 0x2A].contains(ns.character(at: s)) { s += 1 }
        guard s < caret else { return nil }
        // Unbalanced bracket characters mean we cut in the middle of something.
        let r = NSRange(location: s, length: caret - s)
        let abbr = ns.substring(with: r)
        var open = 0
        for ch in abbr {
            if ch == "(" { open += 1 } else if ch == ")" { open -= 1; if open < 0 { return nil } }
        }
        return open == 0 ? (r, abbr) : nil
    }

    static func extractCSSAbbreviation(_ ns: NSString, caret: Int, lineStart: Int) -> (NSRange, String)? {
        var i = caret
        while i > lineStart {
            let c = ns.character(at: i - 1)
            guard isIdentChar(c) && c != 0x3A || c == 0x2E || c == 0x25 || c == 0x21 else { break }
            i -= 1
        }
        guard i < caret else { return nil }
        let r = NSRange(location: i, length: caret - i)
        return (r, ns.substring(with: r))
    }

    // MARK: - Plausibility

    /// In HTML/ISML any word may be a tag. In JSX/Vue/Svelte only known HTML
    /// elements (or a bare `.class`/`#id`) are, so `console.log` + Tab is left alone.
    static func isPlausible(_ abbr: String, flavor: MarkupFlavor) -> Bool {
        if flavor == .html || flavor == .isml { return true }
        guard let first = abbr.first else { return false }
        if first == "." || first == "#" || first == "(" { return abbr.dropFirst().first?.isLetter ?? false }
        var name = ""
        for ch in abbr {
            guard ch.isLetter || ch.isNumber || ch == "-" else { break }
            name.append(ch)
        }
        return knownTags.contains(name.lowercased())
    }

    static let knownTags: Set<String> = [
        "a", "abbr", "address", "article", "aside", "audio", "b", "blockquote", "body", "br", "button", "canvas",
        "caption", "code", "col", "dd", "details", "dialog", "div", "dl", "dt", "em", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "i",
        "iframe", "img", "input", "label", "legend", "li", "link", "main", "meta", "nav", "ol", "optgroup",
        "option", "p", "picture", "pre", "script", "section", "select", "small", "source", "span", "strong",
        "style", "sub", "summary", "sup", "svg", "table", "tbody", "td", "template", "textarea", "tfoot", "th",
        "thead", "time", "title", "tr", "u", "ul", "video",
    ]

    // MARK: - Markup parsing

    private final class Node {
        var tag: String?
        var id: String?
        var classes: [String] = []
        var attrs: [(name: String, value: String?)] = []
        var text: String?
        var repeatCount = 1
        var children: [Node] = []
        weak var parent: Node?
        var isGroup = false
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0

        init(_ s: String) { chars = Array(s) }

        var atEnd: Bool { pos >= chars.count }

        /// Parses a sequence of terms into `container`; stops at `)` (when
        /// `inGroup`) or end of input. Returns false on any syntax error.
        mutating func parseSequence(into root: Node, inGroup: Bool) -> Bool {
            var container = root
            var last: Node?
            var expectTerm = true
            while pos < chars.count {
                let c = chars[pos]
                if c == ")" {
                    return inGroup && !expectTerm
                }
                if expectTerm {
                    guard let term = parseTerm() else { return false }
                    term.parent = container
                    container.children.append(term)
                    last = term
                    expectTerm = false
                    continue
                }
                switch c {
                case ">":
                    guard let l = last, !l.isGroup else { return false }
                    pos += 1; container = l; last = nil; expectTerm = true
                case "+":
                    pos += 1; expectTerm = true
                case "^":
                    while pos < chars.count, chars[pos] == "^" {
                        pos += 1
                        container = container.parent ?? container
                    }
                    if pos < chars.count, chars[pos] == "+" { pos += 1 }
                    expectTerm = true
                default:
                    return false
                }
            }
            return !expectTerm && !inGroup
        }

        mutating func parseTerm() -> Node? {
            let node = Node()
            if pos < chars.count, chars[pos] == "(" {
                pos += 1
                node.isGroup = true
                guard parseSequence(into: node, inGroup: true), pos < chars.count, chars[pos] == ")" else { return nil }
                pos += 1
                if pos < chars.count, chars[pos] == "*" { guard parseRepeat(node) else { return nil } }
                return node
            }
            var any = false
            if pos < chars.count, chars[pos].isLetter || chars[pos] == "$" {
                var name = ""
                while pos < chars.count, chars[pos].isLetter || chars[pos].isNumber || "-:_$@".contains(chars[pos]) {
                    name.append(chars[pos]); pos += 1
                }
                node.tag = name; any = true
            }
            loop: while pos < chars.count {
                switch chars[pos] {
                case ".":
                    pos += 1
                    let v = readIdent()
                    guard !v.isEmpty else { return nil }
                    node.classes.append(v); any = true
                case "#":
                    pos += 1
                    let v = readIdent()
                    guard !v.isEmpty else { return nil }
                    node.id = v; any = true
                case "[":
                    pos += 1
                    guard parseAttributes(node) else { return nil }
                    any = true
                case "{":
                    pos += 1
                    var t = ""
                    while pos < chars.count, chars[pos] != "}" { t.append(chars[pos]); pos += 1 }
                    guard pos < chars.count else { return nil }
                    pos += 1
                    node.text = (node.text ?? "") + t; any = true
                case "*":
                    guard parseRepeat(node) else { return nil }
                    break loop
                default:
                    break loop
                }
            }
            return any ? node : nil
        }

        mutating func parseRepeat(_ node: Node) -> Bool {
            pos += 1
            var digits = ""
            while pos < chars.count, chars[pos].isNumber { digits.append(chars[pos]); pos += 1 }
            guard let n = Int(digits), n >= 1, n <= 500 else { return false }
            node.repeatCount = n
            return true
        }

        mutating func readIdent() -> String {
            var s = ""
            while pos < chars.count, chars[pos].isLetter || chars[pos].isNumber || "-_$@".contains(chars[pos]) {
                s.append(chars[pos]); pos += 1
            }
            return s
        }

        mutating func parseAttributes(_ node: Node) -> Bool {
            while pos < chars.count {
                while pos < chars.count, chars[pos] == " " { pos += 1 }
                if pos < chars.count, chars[pos] == "]" { pos += 1; return true }
                var name = ""
                while pos < chars.count, !" =]".contains(chars[pos]) { name.append(chars[pos]); pos += 1 }
                guard !name.isEmpty, pos < chars.count else { return false }
                var value: String?
                if chars[pos] == "=" {
                    pos += 1
                    var v = ""
                    if pos < chars.count, chars[pos] == "\"" || chars[pos] == "'" {
                        let q = chars[pos]; pos += 1
                        while pos < chars.count, chars[pos] != q { v.append(chars[pos]); pos += 1 }
                        guard pos < chars.count else { return false }
                        pos += 1
                    } else {
                        while pos < chars.count, chars[pos] != " ", chars[pos] != "]" { v.append(chars[pos]); pos += 1 }
                    }
                    value = v
                }
                node.attrs.append((name, value))
            }
            return false
        }
    }

    // MARK: - Numbering

    /// Replaces `$` runs: `$` → index, `$$` → zero-padded, `$@-` counts down,
    /// `$@N` starts at N, `\$` is a literal dollar.
    static func applyNumbering(_ s: String, index: Int, total: Int) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" { out.append("$"); i += 2; continue }
            guard c == "$" else { out.append(c); i += 1; continue }
            var width = 0
            while i < chars.count, chars[i] == "$" { width += 1; i += 1 }
            var descending = false
            var base = 1
            if i < chars.count, chars[i] == "@" {
                var j = i + 1
                if j < chars.count, chars[j] == "-" { descending = true; j += 1 }
                var digits = ""
                while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                if let b = Int(digits) { base = b }
                i = j
            }
            let value = descending ? base + total - index : base + index - 1
            let str = String(value)
            out += String(repeating: "0", count: max(0, width - str.count)) + str
        }
        return out
    }

    // MARK: - Markup rendering

    private struct Output {
        var text = ""
        var stops: [Int] = []
        var utf16Count = 0
        mutating func append(_ s: String) { text += s; utf16Count += s.utf16.count }
        mutating func stop() { stops.append(utf16Count) }
    }

    private static let inlineParents: Set<String> = [
        "p", "a", "abbr", "b", "i", "em", "strong", "span", "label", "button", "small", "code", "sub", "sup", "u",
        "h1", "h2", "h3", "h4", "h5", "h6", "dt", "legend", "caption", "cite",
    ]

    static func implicitTag(parent: String?) -> String {
        guard let p = parent?.lowercased() else { return "div" }
        switch p {
        case "ul", "ol", "menu": return "li"
        case "table", "tbody", "thead", "tfoot": return "tr"
        case "tr": return "td"
        case "select", "optgroup", "datalist": return "option"
        case "colgroup": return "col"
        default: return inlineParents.contains(p) ? "span" : "div"
        }
    }

    /// Expands a markup abbreviation. `baseIndent` is prepended to every line
    /// after the first (the first continues the caret's own line).
    static func expandMarkup(
        _ abbreviation: String, flavor: MarkupFlavor, indentUnit: String, baseIndent: String
    ) -> ExpandedSnippet? {
        var parser = Parser(abbreviation)
        let root = Node()
        guard !abbreviation.isEmpty, parser.parseSequence(into: root, inGroup: false), parser.atEnd else { return nil }
        var out = Output()
        render(root.children, parentTag: nil, depth: 0, index: 1, total: 1,
               flavor: flavor, unit: indentUnit, base: baseIndent, out: &out)
        guard !out.text.isEmpty else { return nil }
        guard !out.stops.isEmpty else { return ExpandedSnippet(text: out.text, tabStops: []) }
        var stops = out.stops.enumerated().map {
            SnippetTabStop(index: $0.offset + 1, range: NSRange(location: $0.element, length: 0))
        }
        stops.append(SnippetTabStop(index: 0, range: NSRange(location: out.utf16Count, length: 0)))
        return ExpandedSnippet(text: out.text, tabStops: stops)
    }

    private static func render(
        _ nodes: [Node], parentTag: String?, depth: Int, index: Int, total: Int,
        flavor: MarkupFlavor, unit: String, base: String, out: inout Output
    ) {
        for node in nodes {
            let reps = node.repeatCount
            for rep in 1...reps {
                let idx = reps > 1 ? rep : index
                let tot = reps > 1 ? reps : total
                if node.isGroup {
                    render(node.children, parentTag: parentTag, depth: depth, index: idx, total: tot,
                           flavor: flavor, unit: unit, base: base, out: &out)
                } else {
                    if !out.text.isEmpty { out.append("\n" + base + String(repeating: unit, count: depth)) }
                    renderElement(node, parentTag: parentTag, depth: depth, index: idx, total: tot,
                                  flavor: flavor, unit: unit, base: base, out: &out)
                }
            }
        }
    }

    private static func renderElement(
        _ node: Node, parentTag: String?, depth: Int, index: Int, total: Int,
        flavor: MarkupFlavor, unit: String, base: String, out: inout Output
    ) {
        func num(_ s: String) -> String { applyNumbering(s, index: index, total: total) }
        var text = node.text.map(num)
        var children = node.children
        // `p>{hi}`: a lone text child stays on the element's line.
        if children.count == 1, let only = children.first, !only.isGroup, only.repeatCount == 1,
           only.tag == nil, only.id == nil, only.classes.isEmpty, only.attrs.isEmpty, let t = only.text {
            text = (text ?? "") + num(t)
            children = []
        }

        if node.tag == nil, node.id == nil, node.classes.isEmpty, node.attrs.isEmpty {
            out.append(text ?? "")
            return
        }
        let tag = num(node.tag ?? implicitTag(parent: parentTag))
        let lower = tag.lowercased()
        let jsx = flavor == .jsx

        out.append("<" + tag)
        if let id = node.id { out.append(" id=\"\(num(id))\"") }
        var classValue = node.classes.map(num).joined(separator: " ")
        var others: [(String, String?)] = []
        for attr in node.attrs {
            if attr.name == "class" || attr.name == "className", let v = attr.value {
                classValue += (classValue.isEmpty ? "" : " ") + num(v)
            } else { others.append((attr.name, attr.value.map(num))) }
        }
        if !classValue.isEmpty { out.append(" \(jsx ? "className" : "class")=\"\(classValue)\"") }
        func rename(_ n: String) -> String {
            guard jsx else { return n }
            return n == "for" ? "htmlFor" : n
        }
        for (name, value) in others {
            out.append(" \(rename(name))=\"\(value ?? "")\"")
        }
        // Default attributes, each with a tab stop when left empty.
        let present = Set(node.attrs.map(\.name))
        for (name, fixed) in defaultAttributes[lower] ?? [] where !present.contains(name) {
            out.append(" \(name)=\"")
            if let fixed { out.append(fixed) } else { out.stop() }
            out.append("\"")
        }

        let isVoid = MarkupFlavor.htmlVoid.contains(lower) || (flavor == .isml && MarkupFlavor.ismlVoid.contains(lower))
        if isVoid {
            out.append(flavor.selfClosesVoidElements ? " />" : ">")
            return
        }
        out.append(">")
        if children.isEmpty {
            if let text { out.append(text) } else { out.stop() }
        } else {
            if let text { out.append(text) }
            render(children, parentTag: tag, depth: depth + 1, index: index, total: total,
                   flavor: flavor, unit: unit, base: base, out: &out)
            out.append("\n" + base + String(repeating: unit, count: depth))
        }
        out.append("</" + tag + ">")
    }

    /// Default attributes per tag; `nil` value means "empty, with a tab stop".
    private static let defaultAttributes: [String: [(String, String?)]] = [
        "a": [("href", nil)],
        "img": [("src", nil), ("alt", nil)],
        "input": [("type", "text")],
        "link": [("rel", "stylesheet"), ("href", nil)],
    ]

    // MARK: - CSS

    private static let cssKeywords: [String: String] = [
        "df": "display: flex", "dif": "display: inline-flex", "dn": "display: none", "db": "display: block",
        "dib": "display: inline-block", "di": "display: inline", "dg": "display: grid", "dc": "display: contents",
        "jcc": "justify-content: center", "jcsb": "justify-content: space-between", "jcsa": "justify-content: space-around",
        "jcfs": "justify-content: flex-start", "jcfe": "justify-content: flex-end", "jcse": "justify-content: space-evenly",
        "aic": "align-items: center", "ais": "align-items: stretch", "aifs": "align-items: flex-start",
        "aife": "align-items: flex-end", "aib": "align-items: baseline",
        "fdc": "flex-direction: column", "fdr": "flex-direction: row", "fww": "flex-wrap: wrap", "fwn": "flex-wrap: nowrap",
        "posa": "position: absolute", "posr": "position: relative", "posf": "position: fixed", "poss": "position: static",
        "post": "position: sticky",
        "tac": "text-align: center", "tal": "text-align: left", "tar": "text-align: right", "taj": "text-align: justify",
        "tdn": "text-decoration: none", "tdu": "text-decoration: underline",
        "ovh": "overflow: hidden", "ova": "overflow: auto", "ovs": "overflow: scroll", "ovv": "overflow: visible",
        "curp": "cursor: pointer", "bxz": "box-sizing: border-box", "bxzbb": "box-sizing: border-box",
        "fwb": "font-weight: bold", "fsi": "font-style: italic", "vh": "visibility: hidden",
        "wsn": "white-space: nowrap", "tt": "text-transform: uppercase", "ttc": "text-transform: capitalize",
    ]

    private static let cssProperties: [String: String] = [
        "m": "margin", "mt": "margin-top", "mr": "margin-right", "mb": "margin-bottom", "ml": "margin-left",
        "p": "padding", "pt": "padding-top", "pr": "padding-right", "pb": "padding-bottom", "pl": "padding-left",
        "w": "width", "h": "height", "mw": "max-width", "mh": "max-height", "miw": "min-width", "mih": "min-height",
        "t": "top", "r": "right", "b": "bottom", "l": "left", "z": "z-index", "fz": "font-size", "fw": "font-weight",
        "lh": "line-height", "op": "opacity", "bdrs": "border-radius", "bd": "border", "c": "color",
        "bg": "background", "gap": "gap", "fx": "flex", "ls": "letter-spacing", "ti": "text-indent", "ord": "order",
    ]

    private static let cssUnitless: Set<String> = [
        "z-index", "opacity", "font-weight", "line-height", "flex", "order",
    ]

    private static let cssUnits: [String: String] = ["p": "%", "e": "em", "r": "rem", "x": "ex"]
    private static let cssLiteralUnits: Set<String> = [
        "px", "em", "rem", "ex", "vh", "vw", "vmin", "vmax", "ch", "pt", "s", "ms", "deg", "fr", "%",
    ]

    /// Expands a CSS abbreviation to a declaration ending in `;`.
    static func expandCSS(_ abbreviation: String) -> ExpandedSnippet? {
        var abbr = abbreviation
        var important = false
        if abbr.hasSuffix("!") { important = true; abbr.removeLast() }
        guard !abbr.isEmpty else { return nil }
        let tail = important ? " !important;" : ";"

        if let kw = cssKeywords[abbr] {
            return ExpandedSnippet(text: kw + tail, tabStops: [])
        }
        // Longest property alias that is followed by nothing or a value.
        let alias = cssProperties.keys.sorted { $0.count > $1.count }.first { key in
            guard abbr.hasPrefix(key) else { return false }
            let rest = abbr.dropFirst(key.count)
            guard let f = rest.first else { return true }
            return f.isNumber || f == "-" || f == "."
        }
        guard let alias, let property = cssProperties[alias] else { return nil }
        let rest = String(abbr.dropFirst(alias.count))
        if rest.isEmpty {
            let head = property + ": "
            let text = head + tail
            let at = head.utf16.count
            return ExpandedSnippet(text: text, tabStops: [
                SnippetTabStop(index: 1, range: NSRange(location: at, length: 0)),
                SnippetTabStop(index: 0, range: NSRange(location: text.utf16.count, length: 0)),
            ])
        }
        var tokens: [String] = []
        var cur = ""
        for ch in rest {
            if ch == "-" {
                if cur.isEmpty { cur = "-" } else { tokens.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty && cur != "-" { tokens.append(cur) }
        guard !tokens.isEmpty else { return nil }
        var values: [String] = []
        for token in tokens {
            guard let v = cssValue(token, unitless: cssUnitless.contains(property)) else { return nil }
            values.append(v)
        }
        return ExpandedSnippet(text: property + ": " + values.joined(separator: " ") + tail, tabStops: [])
    }

    private static func cssValue(_ token: String, unitless: Bool) -> String? {
        if token == "a" { return "auto" }
        var numPart = ""
        var unitPart = ""
        for ch in token {
            if unitPart.isEmpty, ch.isNumber || ch == "." || (ch == "-" && numPart.isEmpty) { numPart.append(ch) }
            else { unitPart.append(ch) }
        }
        guard let digit = numPart.last, digit.isNumber, Double(numPart) != nil else { return nil }
        if unitPart.isEmpty {
            let isZero = Double(numPart) == 0
            return unitless || isZero ? numPart : numPart + "px"
        }
        if let u = cssUnits[unitPart] { return numPart + u }
        if cssLiteralUnits.contains(unitPart) { return numPart + unitPart }
        return nil
    }
}
