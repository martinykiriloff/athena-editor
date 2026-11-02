// MarkupTags.swift
// Athena — pure, NSTextView-independent tag scanning for HTML/ISML/JSX/Vue/Svelte:
// auto-close on ">" and linked rename of paired tag names.
// Swift 6, strict concurrency.

import Foundation

// MARK: - MarkupFlavor

/// The markup dialects the tag helpers (and Emmet) understand. Chosen from the
/// file extension, not from `Language`, because Vue/Svelte have no `Language`
/// case and `.jsx`/`.tsx` share one with plain JavaScript/TypeScript.
enum MarkupFlavor: Sendable, Equatable {
    case html, isml, jsx, vue, svelte

    /// `nil` for files that are not markup, which disables every tag feature.
    static func flavor(forPathExtension ext: String) -> MarkupFlavor? {
        switch ext.lowercased() {
        case "html", "htm", "xhtml": return .html
        case "isml":                 return .isml
        case "jsx", "tsx":           return .jsx
        case "vue":                  return .vue
        case "svelte":               return .svelte
        default:                     return nil
        }
    }

    /// JSX/Svelte/Vue treat `Foo` and `foo` as different tags; HTML does not
    /// (names are compared case-insensitively there).
    var isCaseSensitive: Bool { self != .html && self != .isml }

    /// `<>` … `</>` fragments.
    var allowsFragments: Bool { self == .jsx || self == .vue || self == .svelte }

    /// `{…}` in attribute position may contain `>` (JSX/Svelte expressions).
    var hasBraceAttributes: Bool { self == .jsx || self == .svelte }

    /// Tags that never take a closing tag. Empty for JSX, where an unclosed
    /// `<input>` is a syntax error and so is never "void".
    var voidElements: Set<String> {
        switch self {
        case .jsx:             return []
        case .isml:            return MarkupFlavor.htmlVoid.union(MarkupFlavor.ismlVoid)
        case .html, .vue, .svelte: return MarkupFlavor.htmlVoid
        }
    }

    /// Whether rendered void elements are written `<br />` (true) or `<br>`.
    var selfClosesVoidElements: Bool { self == .jsx || self == .svelte }

    static let htmlVoid: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr",
    ]

    /// ISML tags that stand alone (`<iselse>`, `<isprint …>`).
    static let ismlVoid: Set<String> = [
        "iselse", "iselseif", "isprint", "isset", "isinclude", "isnext", "isbreak",
        "iscontinue", "isredirect", "isslot", "isremove", "iscache", "iscontent",
        "isstatus", "isreplace", "isactivedatahead", "isactivedatacontext",
        "isanalyticsoff", "isanalyticson", "isinputfield", "isselectedoption",
    ]
}

// MARK: - MarkupTags

/// Tag-level text analysis on UTF-16 offsets (`NSRange`), the convention used
/// throughout the editor. Nothing here touches AppKit.
enum MarkupTags {

    /// Documents larger than this (UTF-16 units) are not scanned for pairs.
    static let maxScannedLength = 1_000_000

    // MARK: Tokens

    struct Tag: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case open, close, selfClosing }
        let kind: Kind
        let name: String
        let nameRange: NSRange
        let range: NSRange
    }

    /// A tag name and the name of the tag it pairs with.
    struct NamePair: Sendable, Equatable {
        let name: NSRange
        let partner: NSRange
    }

    /// Replace `range` with `replacement`.
    struct Rename: Sendable, Equatable {
        let range: NSRange
        let replacement: String
    }

    // MARK: Scanning

    /// Every tag in `text`, in document order. Skips comments, `<!…>`/`<?…>`,
    /// quoted attribute values, `{…}` attribute expressions (JSX/Svelte) and the
    /// bodies of `<script>`/`<style>` (non-JSX).
    static func scan(_ text: String, flavor: MarkupFlavor) -> [Tag] {
        let u = Array(text.utf16)
        let n = u.count
        var tags: [Tag] = []
        let voids = flavor.voidElements
        var i = 0
        while i < n {
            guard u[i] == lt else { i += 1; continue }
            if matches(u, at: i, "<!--") {
                i = indexOf(u, "-->", from: i + 4).map { $0 + 3 } ?? n
                continue
            }
            guard i + 1 < n else { break }
            let next = u[i + 1]
            if next == slash {
                let nameStart = i + 2
                let nameEnd = scanName(u, from: nameStart)
                guard nameEnd < n, nameEnd > nameStart || (flavor.allowsFragments && u[nameEnd] == gt) else {
                    i += 1; continue
                }
                var j = nameEnd
                while j < n, u[j] != gt, u[j] != lt { j += 1 }
                guard j < n, u[j] == gt else { i += 1; continue }
                tags.append(Tag(kind: .close, name: string(u, nameStart, nameEnd),
                                nameRange: NSRange(location: nameStart, length: nameEnd - nameStart),
                                range: NSRange(location: i, length: j + 1 - i)))
                i = j + 1
                continue
            }
            let isFragment = next == gt && flavor.allowsFragments
            guard isFragment || isNameStart(next) else { i += 1; continue }
            let nameStart = i + 1
            let nameEnd = isFragment ? nameStart : scanName(u, from: nameStart)
            guard let close = findTagEnd(u, from: nameEnd, braces: flavor.hasBraceAttributes) else {
                i += 1; continue
            }
            let name = string(u, nameStart, nameEnd)
            let selfClosing = close > 0 && u[close - 1] == slash && close - 1 >= nameEnd
            let isVoid = voids.contains(name.lowercased())
            tags.append(Tag(kind: selfClosing || isVoid ? .selfClosing : .open, name: name,
                            nameRange: NSRange(location: nameStart, length: nameEnd - nameStart),
                            range: NSRange(location: i, length: close + 1 - i)))
            i = close + 1
            let lower = name.lowercased()
            if !selfClosing, flavor != .jsx, lower == "script" || lower == "style",
               let end = indexOfCaseInsensitive(u, "</" + lower, from: i) {
                i = end
            }
        }
        return tags
    }

    /// Open-tag index → close-tag index and back, by name-matched stack. A
    /// closing tag closes the nearest open tag of the same name and implicitly
    /// abandons any unclosed tags above it (the tolerant behaviour HTML needs).
    static func pairs(of tags: [Tag], flavor: MarkupFlavor) -> [Int: Int] {
        var stack: [Int] = []
        var result: [Int: Int] = [:]
        func same(_ a: String, _ b: String) -> Bool {
            flavor.isCaseSensitive ? a == b : a.lowercased() == b.lowercased()
        }
        for (idx, tag) in tags.enumerated() {
            switch tag.kind {
            case .selfClosing: continue
            case .open: stack.append(idx)
            case .close:
                guard let pos = stack.lastIndex(where: { same(tags[$0].name, tag.name) }) else { continue }
                let open = stack[pos]
                stack.removeSubrange(pos...)
                result[open] = idx
                result[idx] = open
            }
        }
        return result
    }

    // MARK: Linked rename

    /// The pair whose name contains the whole of `edit` (an edit that merely
    /// touches a name's start or end counts, so typing at either end works), or
    /// `nil` when the edit is not inside a tag name or the tag has no partner.
    /// Call it on the text *before* the edit lands.
    static func namePair(in text: String, flavor: MarkupFlavor, touching edit: NSRange) -> NamePair? {
        let ns = text as NSString
        guard ns.length <= maxScannedLength, isInsideTagName(ns, edit: edit) else { return nil }
        let tags = scan(text, flavor: flavor)
        guard let idx = tags.firstIndex(where: {
            edit.location >= $0.nameRange.location && NSMaxRange(edit) <= NSMaxRange($0.nameRange)
        }) else { return nil }
        guard let partner = pairs(of: tags, flavor: flavor)[idx] else { return nil }
        return NamePair(name: tags[idx].nameRange, partner: tags[partner].nameRange)
    }

    /// The edit that keeps `pair`'s partner in step after `editRange` was
    /// replaced by `replacementLength` UTF-16 units in the text now `newText`.
    /// `nil` when the new name isn't a valid tag name or the partner already
    /// matches.
    static func partnerRename(
        newText: String, pair: NamePair, editRange: NSRange, replacementLength: Int, flavor: MarkupFlavor
    ) -> Rename? {
        let ns = newText as NSString
        let delta = replacementLength - editRange.length
        let newName = NSRange(location: pair.name.location, length: pair.name.length + delta)
        guard newName.length >= 0, NSMaxRange(newName) <= ns.length else { return nil }
        var partner = pair.partner
        if partner.location > pair.name.location { partner.location += delta }
        guard partner.location >= 0, NSMaxRange(partner) <= ns.length else { return nil }

        let value = ns.substring(with: newName)
        if value.isEmpty { guard flavor.allowsFragments else { return nil } }
        else {
            let units = Array(value.utf16)
            guard isNameStart(units[0]), scanName(units, from: 0) == units.count else { return nil }
        }
        guard ns.substring(with: partner) != value else { return nil }
        return Rename(range: partner, replacement: value)
    }

    // MARK: Auto-close

    /// The closing tag (`</div>`) to insert right after a `>` the user is about
    /// to type at `caret`, or `nil` when no closing tag is wanted: not inside an
    /// open tag, a void element, an explicit `/>`, a closing tag already
    /// following, or (in JSX/Vue/Svelte) a TypeScript generic like `Array<string>`.
    /// `text` is the document *without* the `>`.
    static func closingTag(afterTyping caret: Int, in text: String, flavor: MarkupFlavor) -> String? {
        let u = Array(text.utf16)
        guard caret >= 1 || flavor.allowsFragments, caret <= u.count else { return nil }
        let window = max(0, caret - 4000)
        var start = caret - 1
        while start >= window, u[start] != lt { start -= 1 }
        guard start >= window, u[start] == lt else { return nil }

        // Generic arguments, not a tag: `f<T>`, `Array<string>`, `x[0]<y>`.
        if flavor != .html, flavor != .isml, start > 0 {
            let prev = u[start - 1]
            if isNameChar(prev) || prev == 0x29 || prev == 0x5D { return nil }
        }

        let nameStart = start + 1
        let nameEnd = scanName(u, from: nameStart)
        let name = string(u, nameStart, min(nameEnd, caret))
        let isFragment = nameStart == caret && flavor.allowsFragments
        guard isFragment || (nameStart < caret && isNameStart(u[nameStart])) else { return nil }
        guard nameEnd <= caret else { return nil }

        // The text between "<" and the caret must be a still-open tag.
        var quote: UInt16 = 0
        var braces = 0
        var k = nameEnd
        while k < caret {
            let c = u[k]
            if quote != 0 { if c == quote { quote = 0 } }
            else if c == dq || c == sq { quote = c }
            else if flavor.hasBraceAttributes, c == lbrace { braces += 1 }
            else if flavor.hasBraceAttributes, c == rbrace { braces = max(0, braces - 1) }
            else if braces == 0, c == gt || c == lt { return nil }
            k += 1
        }
        guard quote == 0, braces == 0 else { return nil }
        if caret > 0, u[caret - 1] == slash, !isFragment { return nil }

        if flavor.voidElements.contains(name.lowercased()) { return nil }
        let closer = "</" + name + ">"
        if matches(u, at: caret, closer, caseInsensitive: !flavor.isCaseSensitive) { return nil }
        return closer
    }

    // MARK: - Private

    private static let lt: UInt16 = 0x3C, gt: UInt16 = 0x3E, slash: UInt16 = 0x2F
    private static let dq: UInt16 = 0x22, sq: UInt16 = 0x27
    private static let lbrace: UInt16 = 0x7B, rbrace: UInt16 = 0x7D

    private static func isNameStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isNameChar(_ c: UInt16) -> Bool {
        isNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F || c == 0x2E || c == 0x3A
    }

    private static func scanName(_ u: [UInt16], from start: Int) -> Int {
        var i = start
        while i < u.count, isNameChar(u[i]) { i += 1 }
        return i
    }

    private static func string(_ u: [UInt16], _ from: Int, _ to: Int) -> String {
        guard to > from else { return "" }
        return String(decoding: u[from..<to], as: UTF16.self)
    }

    private static func matches(_ u: [UInt16], at i: Int, _ s: String, caseInsensitive: Bool = false) -> Bool {
        let pattern = Array(s.utf16)
        guard i >= 0, i + pattern.count <= u.count else { return false }
        for (offset, p) in pattern.enumerated() {
            let c = u[i + offset]
            if c == p { continue }
            if caseInsensitive, lower(c) == lower(p) { continue }
            return false
        }
        return true
    }

    private static func lower(_ c: UInt16) -> UInt16 { (c >= 0x41 && c <= 0x5A) ? c + 32 : c }

    private static func indexOf(_ u: [UInt16], _ s: String, from: Int) -> Int? {
        var i = from
        while i < u.count { if matches(u, at: i, s) { return i }; i += 1 }
        return nil
    }

    private static func indexOfCaseInsensitive(_ u: [UInt16], _ s: String, from: Int) -> Int? {
        var i = from
        while i < u.count { if matches(u, at: i, s, caseInsensitive: true) { return i }; i += 1 }
        return nil
    }

    /// Index of the `>` that ends the tag whose name ended at `from`, or `nil`
    /// for a malformed tag (a `<` outside quotes/braces first, or end of text).
    private static func findTagEnd(_ u: [UInt16], from: Int, braces: Bool) -> Int? {
        var quote: UInt16 = 0
        var depth = 0
        var j = from
        while j < u.count {
            let c = u[j]
            if quote != 0 { if c == quote { quote = 0 } }
            else if c == dq || c == sq { quote = c }
            else if braces, c == lbrace { depth += 1 }
            else if braces, c == rbrace { depth = max(0, depth - 1) }
            else if depth == 0 {
                if c == gt { return j }
                if c == lt { return nil }
            }
            j += 1
        }
        return nil
    }

    /// Cheap pre-check so ordinary typing never pays for a whole-document scan:
    /// is the edit sitting in a run of name characters directly after `<` or `</`?
    private static func isInsideTagName(_ ns: NSString, edit: NSRange) -> Bool {
        var i = min(edit.location, ns.length)
        while i > 0, isNameChar(ns.character(at: i - 1)) { i -= 1 }
        if i > 0, ns.character(at: i - 1) == lt { return true }
        if i > 1, ns.character(at: i - 1) == slash, ns.character(at: i - 2) == lt { return true }
        return false
    }
}
