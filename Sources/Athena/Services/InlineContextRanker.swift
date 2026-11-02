// InlineContextRanker.swift
// Athena — picks what other code an inline completion should see: the most
// similar windows of open tabs, outlines of imported files, and which files
// must never be sent anywhere.
// Swift 6, strict concurrency.

import Foundation

enum InlineContextRanker {

    // MARK: - File policy

    /// Files whose contents must never leave the editor as context, and in
    /// which ghost text is never requested at all: secrets, keys, and
    /// credentials. Matched on the file name, case-insensitively.
    static func isSensitive(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return true }
        let exact: Set<String> = [
            ".npmrc", ".netrc", ".pypirc", ".dockercfg", ".git-credentials", ".htpasswd",
            "credentials", "credentials.json", "secrets.json", "secrets.yaml", "secrets.yml",
            "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "service-account.json",
        ]
        if exact.contains(name) { return true }
        let extensions: Set<String> = [
            "pem", "key", "p12", "pfx", "keystore", "jks", "crt", "cer", "der",
            "tfvars", "tfstate", "kdbx", "asc", "gpg",
        ]
        if extensions.contains((name as NSString).pathExtension) { return true }
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") { return true }
        return false
    }

    /// Files where ghost text is noise rather than help: lockfiles,
    /// minified bundles, source maps, and anything very large.
    static func isNoise(path: String, length: Int) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let lockfiles: Set<String> = [
            "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
            "composer.lock", "gemfile.lock", "cargo.lock", "poetry.lock", "package.resolved",
        ]
        if lockfiles.contains(name) { return true }
        if name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".map") { return true }
        return length > 1_000_000
    }

    // MARK: - Similar windows of other files

    /// The windows of `documents` most similar to `query` (the lines just
    /// above the caret), by Jaccard similarity of identifier sets — the
    /// "neighboring tabs" approach. Returns at most `limit` snippets, best
    /// first, within `maxChars` in total.
    static func bestWindows(
        query: String,
        documents: [(path: String, text: String)],
        windowLines: Int = 20,
        step: Int = 10,
        limit: Int = 3,
        minScore: Double = 0.12,
        maxChars: Int
    ) -> [InlineContextSnippet] {
        let queryTokens = tokens(in: query)
        guard queryTokens.count >= 3, maxChars > 0 else { return [] }

        var scored: [(score: Double, snippet: InlineContextSnippet)] = []
        for doc in documents {
            let lines = doc.text.components(separatedBy: "\n")
            guard !lines.isEmpty else { continue }
            var best: (score: Double, start: Int)?
            var start = 0
            repeat {
                let end = min(start + windowLines, lines.count)
                let window = lines[start..<end].joined(separator: "\n")
                let windowTokens = tokens(in: window)
                if !windowTokens.isEmpty {
                    let shared = queryTokens.intersection(windowTokens).count
                    let union = queryTokens.union(windowTokens).count
                    let score = union == 0 ? 0 : Double(shared) / Double(union)
                    if score > (best?.score ?? 0) { best = (score, start) }
                }
                start += step
            } while start < lines.count - step / 2

            if let best, best.score >= minScore {
                let end = min(best.start + windowLines, lines.count)
                let text = lines[best.start..<end].joined(separator: "\n")
                scored.append((best.score, InlineContextSnippet(path: doc.path, text: text)))
            }
        }

        var result: [InlineContextSnippet] = []
        var used = 0
        for item in scored.sorted(by: { $0.score > $1.score }).prefix(limit) {
            let cost = item.snippet.text.count + item.snippet.path.count
            guard used + cost <= maxChars else { continue }
            result.append(item.snippet)
            used += cost
        }
        return result
    }

    /// Identifier-like tokens of two or more characters.
    static func tokens(in text: String) -> Set<String> {
        var result = Set<String>()
        var current = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$" {
                current.unicodeScalars.append(scalar)
            } else {
                if current.count >= 2 { result.insert(current) }
                current = ""
            }
        }
        if current.count >= 2 { result.insert(current) }
        return result
    }

    // MARK: - Imported files

    /// Module specifiers the file imports (`'./user'`, `"@/lib/db"`), first
    /// `limit` of them, skipping bare package names (node_modules typings
    /// are huge and mostly noise for a completion).
    static func importSpecifiers(in text: String, limit: Int = 6) -> [String] {
        var result: [String] = []
        for line in importLines(in: text) {
            guard let spec = lastQuoted(in: line) else { continue }
            let local = spec.hasPrefix(".") || spec.hasPrefix("/") || spec.hasPrefix("@/") || spec.hasPrefix("~/") || spec.hasPrefix("#")
            guard local, !result.contains(spec) else { continue }
            result.append(spec)
            if result.count == limit { break }
        }
        return result
    }

    /// A compact outline of a file: its declaration and export lines, which
    /// are what a completion needs to call into it correctly.
    static func outline(of text: String, maxLines: Int = 25) -> String {
        let starts = [
            "export ", "func ", "public ", "class ", "struct ", "enum ", "protocol ", "interface ",
            "type ", "def ", "async def ", "function ", "async function ", "const ", "let ", "var ",
            "module.exports", "exports.", "fn ", "pub ", "actor ", "extension ",
        ]
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            // Top-level or one indent level deep (methods, members).
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            guard indent <= 4 else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard starts.contains(where: { line.hasPrefix($0) }) else { continue }
            // Keep signatures, not bodies.
            var signature = line
            if let brace = signature.firstIndex(of: "{") { signature = String(signature[..<brace]).trimmingCharacters(in: .whitespaces) }
            if signature.count > 160 { signature = String(signature.prefix(160)) + "…" }
            lines.append(String(repeating: " ", count: min(indent, 4)) + signature)
            if lines.count == maxLines { break }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Identifiers near the caret

    /// Identifiers on the last `lines` lines before the caret, most recent
    /// first, with their 1-based line and UTF-16 column — the symbols whose
    /// definitions are worth fetching from the language server.
    static func identifiersNearCaret(prefix: String, lines: Int = 3, limit: Int = 4) -> [(name: String, line: Int, column: Int)] {
        let all = prefix.components(separatedBy: "\n")
        let firstLine = max(0, all.count - lines)
        var found: [(name: String, line: Int, column: Int)] = []
        var seen = Set<String>()
        for index in stride(from: all.count - 1, through: firstLine, by: -1) {
            let ns = all[index] as NSString
            var hits: [(String, Int)] = []
            var i = 0
            while i < ns.length {
                let c = ns.character(at: i)
                if isIdentifierStart(c) {
                    let start = i
                    while i < ns.length, isIdentifierPart(ns.character(at: i)) { i += 1 }
                    hits.append((ns.substring(with: NSRange(location: start, length: i - start)), start))
                } else {
                    i += 1
                }
            }
            for (name, column) in hits.reversed() where name.count >= 3 && !keywords.contains(name) && !seen.contains(name) {
                seen.insert(name)
                found.append((name, index + 1, column + 1))
                if found.count == limit { return found }
            }
        }
        return found
    }

    // MARK: - Private

    private static let keywords: Set<String> = [
        "const", "let", "var", "function", "return", "async", "await", "import", "export", "from",
        "default", "class", "extends", "new", "this", "self", "super", "true", "false", "null",
        "undefined", "nil", "func", "struct", "enum", "protocol", "extension", "guard", "else",
        "for", "while", "switch", "case", "break", "continue", "throw", "throws", "try", "catch",
        "type", "interface", "public", "private", "static", "void", "def", "pass", "None", "True",
        "False", "elif", "with", "yield", "typeof", "instanceof", "string", "number", "boolean",
        "any", "unknown", "never", "readonly", "implements", "package", "where", "some",
    ]

    private static func isIdentifierStart(_ c: unichar) -> Bool {
        c == 95 || c == 36 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    private static func isIdentifierPart(_ c: unichar) -> Bool {
        isIdentifierStart(c) || (c >= 48 && c <= 57)
    }

    private static func lastQuoted(in line: String) -> String? {
        var last: String?
        var quote: Character?
        var current = ""
        for c in line {
            if let q = quote {
                if c == q { if !current.isEmpty { last = current }; quote = nil; current = "" }
                else { current.append(c) }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            }
        }
        return last
    }
}
