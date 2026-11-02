// TailwindSupport.swift
// Athena — built-in Tailwind awareness: class-name completion and colour
// token detection for inline swatches. Static (Tailwind v3 default palette
// and common utilities); the project's own tailwind.config is not read.
// Swift 6, strict concurrency.

import Foundation
@preconcurrency import AppKit

enum TailwindSupport {

    // MARK: - Palette

    /// Default v3 palette, shades 50…950 in order.
    private static let shades = ["50", "100", "200", "300", "400", "500", "600", "700", "800", "900", "950"]
    private static let paletteHex: [String: String] = [
        "slate": "f8fafc f1f5f9 e2e8f0 cbd5e1 94a3b8 64748b 475569 334155 1e293b 0f172a 020617",
        "gray": "f9fafb f3f4f6 e5e7eb d1d5db 9ca3af 6b7280 4b5563 374151 1f2937 111827 030712",
        "zinc": "fafafa f4f4f5 e4e4e7 d4d4d8 a1a1aa 71717a 52525b 3f3f46 27272a 18181b 09090b",
        "neutral": "fafafa f5f5f5 e5e5e5 d4d4d4 a3a3a3 737373 525252 404040 262626 171717 0a0a0a",
        "stone": "fafaf9 f5f5f4 e7e5e4 d6d3d1 a8a29e 78716c 57534e 44403c 292524 1c1917 0c0a09",
        "red": "fef2f2 fee2e2 fecaca fca5a5 f87171 ef4444 dc2626 b91c1c 991b1b 7f1d1d 450a0a",
        "orange": "fff7ed ffedd5 fed7aa fdba74 fb923c f97316 ea580c c2410c 9a3412 7c2d12 431407",
        "amber": "fffbeb fef3c7 fde68a fcd34d fbbf24 f59e0b d97706 b45309 92400e 78350f 451a03",
        "yellow": "fefce8 fef9c3 fef08a fde047 facc15 eab308 ca8a04 a16207 854d0e 713f12 422006",
        "lime": "f7fee7 ecfccb d9f99d bef264 a3e635 84cc16 65a30d 4d7c0f 3f6212 365314 1a2e05",
        "green": "f0fdf4 dcfce7 bbf7d0 86efac 4ade80 22c55e 16a34a 15803d 166534 14532d 052e16",
        "emerald": "ecfdf5 d1fae5 a7f3d0 6ee7b7 34d399 10b981 059669 047857 065f46 064e3b 022c22",
        "teal": "f0fdfa ccfbf1 99f6e4 5eead4 2dd4bf 14b8a6 0d9488 0f766e 115e59 134e4a 042f2e",
        "cyan": "ecfeff cffafe a5f3fc 67e8f9 22d3ee 06b6d4 0891b2 0e7490 155e75 164e63 083344",
        "sky": "f0f9ff e0f2fe bae6fd 7dd3fc 38bdf8 0ea5e9 0284c7 0369a1 075985 0c4a6e 082f49",
        "blue": "eff6ff dbeafe bfdbfe 93c5fd 60a5fa 3b82f6 2563eb 1d4ed8 1e40af 1e3a8a 172554",
        "indigo": "eef2ff e0e7ff c7d2fe a5b4fc 818cf8 6366f1 4f46e5 4338ca 3730a3 312e81 1e1b4b",
        "violet": "f5f3ff ede9fe ddd6fe c4b5fd a78bfa 8b5cf6 7c3aed 6d28d9 5b21b6 4c1d95 2e1065",
        "purple": "faf5ff f3e8ff e9d5ff d8b4fe c084fc a855f7 9333ea 7e22ce 6b21a8 581c87 3b0764",
        "fuchsia": "fdf4ff fae8ff f5d0fe f0abfc e879f9 d946ef c026d3 a21caf 86198f 701a75 4a044e",
        "pink": "fdf2f8 fce7f3 fbcfe8 f9a8d4 f472b6 ec4899 db2777 be185d 9d174d 831843 500724",
        "rose": "fff1f2 ffe4e6 fecdd3 fda4af fb7185 f43f5e e11d48 be123c 9f1239 881337 4c0519",
    ]
    private static let colorPrefixes = [
        "bg", "text", "border", "ring", "outline", "fill", "stroke", "from", "via", "to",
        "divide", "accent", "caret", "decoration", "shadow", "placeholder",
    ]
    private static let namedColors: [String: UInt32] = [
        "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "black": 0x000000, "white": 0xFFFFFF,
        "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080, "pink": 0xFFC0CB,
        "gray": 0x808080, "grey": 0x808080, "cyan": 0x00FFFF, "magenta": 0xFF00FF,
    ]

    /// `"red-500"` → 0xEF4444, `"white"`, `"black"`; nil for anything else.
    static func hex(forColorName name: String) -> UInt32? {
        if name == "white" { return 0xFFFFFF }
        if name == "black" { return 0x000000 }
        let parts = name.split(separator: "-")
        guard parts.count == 2, let row = paletteHex[String(parts[0])],
              let index = shades.firstIndex(of: String(parts[1])) else { return nil }
        let values = row.split(separator: " ")
        return UInt32(values[index], radix: 16)
    }

    // MARK: - Colour tokens

    struct ColorToken: Equatable {
        var range: NSRange
        var hex: UInt32
        var alpha: Double
    }

    private static let tokenRegex: NSRegularExpression = {
        let prefixes = colorPrefixes.joined(separator: "|")
        let names = paletteHex.keys.sorted().joined(separator: "|")
        let pattern = "(?<![\\w-])(?:\(prefixes))-(?:(white|black|(?:\(names))-(?:50|100|200|300|400|500|600|700|800|900|950))|\\[([#\\w]+)\\])(?:/(\\d{1,3}))?(?![\\w-])"
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Colour utilities in `text` (`bg-red-500`, `text-white/50`,
    /// `border-[#ff8800]`, `bg-[red]`), with the colour they paint.
    static func colorTokens(in text: String, range: NSRange? = nil) -> [ColorToken] {
        let ns = text as NSString
        let scope = range ?? NSRange(location: 0, length: ns.length)
        return tokenRegex.matches(in: text, range: scope).compactMap { m in
            var value: UInt32?
            if m.range(at: 1).location != NSNotFound {
                value = hex(forColorName: ns.substring(with: m.range(at: 1)))
            } else if m.range(at: 2).location != NSNotFound {
                value = parseArbitrary(ns.substring(with: m.range(at: 2)))
            }
            guard let value else { return nil }
            var alpha = 1.0
            if m.range(at: 3).location != NSNotFound, let pct = Double(ns.substring(with: m.range(at: 3))) {
                alpha = min(max(pct / 100, 0), 1)
            }
            return ColorToken(range: m.range, hex: value, alpha: alpha)
        }
    }

    /// `#abc`, `#aabbcc` (alpha digits ignored) or a basic CSS colour name.
    static func parseArbitrary(_ raw: String) -> UInt32? {
        if raw.hasPrefix("#") {
            var digits = String(raw.dropFirst())
            if digits.count == 3 || digits.count == 4 {
                digits = digits.prefix(3).map { "\($0)\($0)" }.joined()
            }
            guard digits.count >= 6 else { return nil }
            return UInt32(digits.prefix(6), radix: 16)
        }
        return namedColors[raw.lowercased()]
    }

    /// Files whose class strings should get colour bars.
    static func supportsSwatches(fileURL: URL?) -> Bool {
        guard let ext = fileURL?.pathExtension.lowercased() else { return false }
        return ["html", "htm", "jsx", "tsx", "vue", "svelte", "astro", "mdx", "css", "scss"].contains(ext)
    }

    // MARK: - Project detection

    static func isTailwindProject(at root: URL) -> Bool {
        let fm = FileManager.default
        for ext in ["js", "cjs", "mjs", "ts"] where fm.fileExists(atPath: root.appendingPathComponent("tailwind.config.\(ext)").path) {
            return true
        }
        return WorkspaceDetector.hasDependency("tailwindcss", in: root)
    }

    // MARK: - Completion

    private static let keywordClasses = [
        "block", "inline-block", "inline", "flex", "inline-flex", "grid", "inline-grid", "hidden", "contents",
        "flex-row", "flex-col", "flex-wrap", "flex-nowrap", "flex-1", "flex-auto", "flex-none", "grow", "shrink",
        "items-start", "items-center", "items-end", "items-stretch", "items-baseline",
        "justify-start", "justify-center", "justify-end", "justify-between", "justify-around", "justify-evenly",
        "self-auto", "self-start", "self-center", "self-end",
        "relative", "absolute", "fixed", "sticky", "static",
        "overflow-hidden", "overflow-auto", "overflow-scroll", "overflow-visible", "overflow-x-auto", "overflow-y-auto",
        "w-full", "w-screen", "w-auto", "w-fit", "h-full", "h-screen", "h-auto", "h-fit", "min-h-screen", "min-w-0",
        "max-w-xs", "max-w-sm", "max-w-md", "max-w-lg", "max-w-xl", "max-w-2xl", "max-w-3xl", "max-w-4xl",
        "max-w-5xl", "max-w-6xl", "max-w-7xl", "max-w-full", "max-w-screen-lg", "mx-auto",
        "text-xs", "text-sm", "text-base", "text-lg", "text-xl", "text-2xl", "text-3xl", "text-4xl", "text-5xl",
        "text-left", "text-center", "text-right", "text-justify",
        "font-thin", "font-light", "font-normal", "font-medium", "font-semibold", "font-bold", "font-extrabold",
        "italic", "underline", "line-through", "no-underline", "uppercase", "lowercase", "capitalize", "truncate",
        "leading-none", "leading-tight", "leading-snug", "leading-normal", "leading-relaxed", "leading-loose",
        "tracking-tight", "tracking-normal", "tracking-wide",
        "rounded", "rounded-none", "rounded-sm", "rounded-md", "rounded-lg", "rounded-xl", "rounded-2xl", "rounded-3xl", "rounded-full",
        "border", "border-0", "border-2", "border-4", "border-8", "border-t", "border-b", "border-l", "border-r",
        "border-solid", "border-dashed", "border-dotted", "border-none",
        "shadow", "shadow-sm", "shadow-md", "shadow-lg", "shadow-xl", "shadow-2xl", "shadow-none",
        "opacity-0", "opacity-25", "opacity-50", "opacity-75", "opacity-100",
        "cursor-pointer", "cursor-default", "cursor-not-allowed", "pointer-events-none", "select-none",
        "transition", "transition-all", "transition-colors", "transition-opacity", "transition-transform",
        "duration-75", "duration-100", "duration-150", "duration-200", "duration-300", "duration-500", "duration-700",
        "ease-in", "ease-out", "ease-in-out", "animate-spin", "animate-pulse", "animate-bounce", "animate-ping",
        "grid-cols-1", "grid-cols-2", "grid-cols-3", "grid-cols-4", "grid-cols-5", "grid-cols-6", "grid-cols-12",
        "col-span-1", "col-span-2", "col-span-3", "col-span-4", "col-span-6", "col-span-full",
        "z-0", "z-10", "z-20", "z-30", "z-40", "z-50", "sr-only", "object-cover", "object-contain", "aspect-square", "aspect-video",
        "whitespace-nowrap", "whitespace-pre", "break-words", "outline-none", "ring", "ring-1", "ring-2", "ring-4",
        "inset-0", "inset-x-0", "inset-y-0", "top-0", "right-0", "bottom-0", "left-0", "container", "antialiased",
    ]
    private static let spacingPrefixes = [
        "p", "px", "py", "pt", "pr", "pb", "pl", "m", "mx", "my", "mt", "mr", "mb", "ml",
        "w", "h", "size", "gap", "gap-x", "gap-y", "space-x", "space-y", "top", "right", "bottom", "left", "inset",
    ]
    private static let spacingScale = [
        "0", "0.5", "1", "1.5", "2", "2.5", "3", "3.5", "4", "5", "6", "7", "8", "9", "10", "11", "12",
        "14", "16", "20", "24", "28", "32", "36", "40", "44", "48", "52", "56", "60", "64", "72", "80", "96", "px",
    ]
    static let variants = [
        "sm", "md", "lg", "xl", "2xl", "hover", "focus", "focus-visible", "active", "disabled", "dark",
        "first", "last", "odd", "even", "group-hover", "peer-focus", "placeholder", "motion-safe", "print",
    ]

    /// Every class the built-in list knows, sorted. Built once.
    static let allClasses: [String] = {
        var set = Set(keywordClasses)
        for prefix in spacingPrefixes { for step in spacingScale { set.insert("\(prefix)-\(step)") } }
        for prefix in colorPrefixes {
            set.insert("\(prefix)-white"); set.insert("\(prefix)-black"); set.insert("\(prefix)-transparent")
            for name in paletteHex.keys { for shade in shades { set.insert("\(prefix)-\(name)-\(shade)") } }
        }
        return set.sorted()
    }()

    /// The partial class token under the caret when it sits inside a class
    /// list (`class="…"`, `className={"…"}`, `@apply …`, or a string inside
    /// `clsx(`/`cn(`/`cva(`/`twMerge(`/`classNames(`), else nil. `linePrefix`
    /// is the current line up to the caret.
    static func classToken(inLinePrefix linePrefix: String) -> String? {
        let ns = linePrefix as NSString
        var tail: String?
        var openQuote: Character?

        if let m = attributeRegex.matches(in: linePrefix, range: NSRange(location: 0, length: ns.length)).last {
            let rest = ns.substring(from: NSMaxRange(m.range))
            let quote = Character(ns.substring(with: m.range(at: 2)))
            guard !rest.contains(quote) else { return finishApply(linePrefix) }
            tail = rest; openQuote = quote
        } else if let m = functionRegex.matches(in: linePrefix, range: NSRange(location: 0, length: ns.length)).last {
            let rest = ns.substring(from: NSMaxRange(m.range))
            for ch in rest {
                if let q = openQuote { if ch == q { openQuote = nil } }
                else if ch == "\"" || ch == "'" || ch == "`" { openQuote = ch }
            }
            guard let q = openQuote, let start = rest.lastIndex(of: q) else { return finishApply(linePrefix) }
            tail = String(rest[rest.index(after: start)...])
        } else {
            return finishApply(linePrefix)
        }
        guard let tail else { return nil }
        return tail.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init)
    }

    private static func finishApply(_ linePrefix: String) -> String? {
        guard let r = linePrefix.range(of: "@apply ", options: .backwards) else { return nil }
        let rest = linePrefix[r.upperBound...]
        guard !rest.contains(";") else { return nil }
        return rest.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init)
    }

    private static let attributeRegex = try! NSRegularExpression(
        pattern: #"\b(class|className|ngClass)\s*=\s*(?:\{\s*)?(["'`])"#)
    private static let functionRegex = try! NSRegularExpression(
        pattern: #"\b(?:clsx|cn|cva|twMerge|classNames|cx|tw)\("#)

    /// Completion items for `token` (the partial class, possibly carrying
    /// variants like `md:hover:`). `wordLength` is the length of the
    /// identifier-characters run the editor will replace on accept; each
    /// item's insert text is the class with the already-typed leading part
    /// removed, so only that run is replaced.
    static func completions(forToken token: String, wordLength: Int, limit: Int = 60) -> [CompletionItem] {
        guard !token.isEmpty, wordLength > 0, wordLength <= token.count else { return [] }
        let base: String
        if let colon = token.lastIndex(of: ":") { base = String(token[token.index(after: colon)...]) } else { base = token }
        guard wordLength <= base.count else { return [] }
        let skip = base.count - wordLength
        var items: [CompletionItem] = []
        for cls in allClasses where cls.hasPrefix(base) && cls.count > base.count {
            let insert = String(cls.dropFirst(skip))
            var item = CompletionItem(label: cls, kind: "tailwind", detail: colorDetail(for: cls), insertText: insert)
            item.filterText = insert
            item.sortText = cls
            items.append(item)
            if items.count >= limit { break }
        }
        return items
    }

    private static func colorDetail(for cls: String) -> String? {
        guard let token = colorTokens(in: cls).first, token.range.length == cls.count else { return nil }
        return String(format: "#%06X", token.hex)
    }
}
