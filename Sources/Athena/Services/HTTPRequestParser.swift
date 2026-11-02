// HTTPRequestParser.swift
// Athena — parses .http / .rest files (VS Code REST Client / JetBrains syntax) and pretty-prints JSON.
// Swift 6, strict concurrency.

import Foundation

enum HTTPRequestParser {

    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "CONNECT"]

    static func isHTTPFile(_ url: URL?) -> Bool {
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return ext == "http" || ext == "rest"
    }

    // MARK: - Parse

    /// Every request in the file with `{{variables}}` already substituted
    /// (file variables `@name = value`, in order, may reference earlier ones;
    /// `{{$guid}}`, `{{$timestamp}}`, `{{$datetime}}`, `{{$randomInt}}` and
    /// `{{$processEnv NAME}}` are dynamic).
    static func parse(_ text: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                      now: Date = Date()) -> [HTTPRequestSpec] {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let variables = fileVariables(lines)

        // Split into blocks at `###`.
        struct Block { var name: String?; var lines: [(Int, String)] }
        var blocks: [Block] = [Block(name: nil, lines: [])]
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("###") {
                let name = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(name: name.isEmpty ? nil : name, lines: []))
            } else {
                blocks[blocks.count - 1].lines.append((i + 1, line))
            }
        }

        var result: [HTTPRequestSpec] = []
        for block in blocks {
            var name = block.name
            var idx = 0
            let ls = block.lines
            // Skip blanks, comments, variable definitions before the request line.
            var requestLineIndex: Int?
            while idx < ls.count {
                let t = ls[idx].1.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { idx += 1; continue }
                if let n = nameDirective(t) { name = n; idx += 1; continue }
                if isComment(t) || isVariableDefinition(t) { idx += 1; continue }
                requestLineIndex = idx
                break
            }
            guard let rli = requestLineIndex else { continue }
            guard let (method, rawURL) = parseRequestLine(ls[rli].1.trimmingCharacters(in: .whitespaces)) else { continue }
            var url = rawURL
            idx = rli + 1
            // Continuation lines: ?a=1 / &b=2
            while idx < ls.count {
                let t = ls[idx].1.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("?") || t.hasPrefix("&") { url += t; idx += 1 } else { break }
            }
            if let range = url.range(of: #"\s+HTTP/\d(\.\d)?$"#, options: .regularExpression) { url.removeSubrange(range) }
            // Headers until a blank line.
            var headers: [HTTPHeader] = []
            while idx < ls.count {
                let raw = ls[idx].1
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if isComment(t) { idx += 1; continue }
                if let colon = t.firstIndex(of: ":") {
                    headers.append(HTTPHeader(name: String(t[..<colon]).trimmingCharacters(in: .whitespaces),
                                              value: String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                }
                idx += 1
            }
            // Body: everything after the blank line, comments and variable
            // definitions (only when outside the body they'd be data) kept.
            var bodyLines: [String] = []
            if idx < ls.count {
                idx += 1
                while idx < ls.count {
                    let t = ls[idx].1.trimmingCharacters(in: .whitespaces)
                    if bodyLines.isEmpty, isComment(t) { idx += 1; continue }
                    bodyLines.append(ls[idx].1)
                    idx += 1
                }
            }
            while let last = bodyLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines.removeLast() }
            let body = bodyLines.isEmpty ? nil : bodyLines.joined(separator: "\n")

            func sub(_ s: String) -> String { substitute(s, variables: variables, environment: environment, now: now) }
            result.append(HTTPRequestSpec(
                name: name, method: method, url: sub(url),
                headers: headers.map { HTTPHeader(name: sub($0.name), value: sub($0.value)) },
                body: body.map(sub),
                startLine: ls[rli].0,
                endLine: ls.last?.0 ?? ls[rli].0))
        }
        return result
    }

    /// The request whose block contains `line` (1-based); a `###` separator
    /// line selects the request it introduces; below the last block, the last request.
    static func request(atLine line: Int, in requests: [HTTPRequestSpec]) -> HTTPRequestSpec? {
        requests.first(where: { line <= $0.endLine }) ?? requests.last
    }

    // MARK: - Pieces

    static func fileVariables(_ lines: [String]) -> [String: String] {
        var vars: [String: String] = [:]
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard isVariableDefinition(t), let eq = t.firstIndex(of: "=") else { continue }
            let name = t[t.index(after: t.startIndex)..<eq].trimmingCharacters(in: .whitespaces)
            var value = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            value = substitute(value, variables: vars, environment: [:], now: Date(), keepUnknown: true)
            vars[name] = value
        }
        return vars
    }

    static func isVariableDefinition(_ t: String) -> Bool {
        guard t.hasPrefix("@"), let eq = t.firstIndex(of: "=") else { return false }
        let name = t[t.index(after: t.startIndex)..<eq].trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !name.contains(" ")
    }

    static func isComment(_ t: String) -> Bool { t.hasPrefix("#") || t.hasPrefix("//") }

    /// `# @name login` / `// @name login`.
    static func nameDirective(_ t: String) -> String? {
        guard isComment(t) else { return nil }
        let rest = t.drop(while: { $0 == "#" || $0 == "/" || $0 == " " })
        guard rest.hasPrefix("@name ") else { return nil }
        let name = rest.dropFirst(6).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func parseRequestLine(_ t: String) -> (String, String)? {
        let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        var method = "GET"
        var rest = t
        if methods.contains(parts[0].uppercased()), parts.count == 2 {
            method = parts[0].uppercased()
            rest = parts[1]
        } else if parts.count == 1, methods.contains(parts[0].uppercased()) {
            return nil
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        // Strip a trailing `HTTP/1.1`.
        if let range = rest.range(of: #"\s+HTTP/\d(\.\d)?$"#, options: .regularExpression) { rest.removeSubrange(range) }
        guard rest.hasPrefix("http") || rest.hasPrefix("{{") || rest.hasPrefix("/") else { return nil }
        return (method, rest)
    }

    static func substitute(_ input: String, variables: [String: String], environment: [String: String],
                           now: Date, keepUnknown: Bool = true) -> String {
        guard input.contains("{{") else { return input }
        var out = ""
        var rest = Substring(input)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else { out += rest[open.lowerBound...]; rest = ""; break }
            let key = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = resolve(key, variables: variables, environment: environment, now: now) {
                out += value
            } else if keepUnknown {
                out += "{{\(key)}}"
            }
            rest = afterOpen[close.upperBound...]
        }
        out += rest
        return out
    }

    private static func resolve(_ key: String, variables: [String: String], environment: [String: String], now: Date) -> String? {
        if key.hasPrefix("$") {
            let parts = key.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            switch parts.first {
            case "$guid", "$uuid": return UUID().uuidString.lowercased()
            case "$timestamp": return String(Int(now.timeIntervalSince1970))
            case "$datetime": return ISO8601DateFormatter().string(from: now)
            case "$randomInt":
                let lo = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                let hi = parts.count > 2 ? Int(parts[2]) ?? 1000 : 1000
                return String(Int.random(in: min(lo, hi)...max(lo, hi)))
            case "$processEnv": return parts.count > 1 ? environment[parts[1]] ?? "" : nil
            default: return nil
            }
        }
        return variables[key]
    }
}

// MARK: - JSON pretty printer

enum JSONPrettyPrinter {
    /// Re-indents valid JSON without reordering keys (JSONSerialization
    /// would). Returns nil if `text` isn't JSON.
    static func format(_ text: String, indent: String = "  ") -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        var out = ""
        var level = 0
        var inString = false
        var escaped = false
        let chars = Array(text)
        var i = 0
        func newline() { out += "\n" + String(repeating: indent, count: level) }
        func nextSignificant(_ from: Int) -> Character? {
            var j = from
            while j < chars.count { if !chars[j].isWhitespace { return chars[j] }; j += 1 }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true; out.append(c)
                case "{", "[":
                    out.append(c)
                    let close: Character = c == "{" ? "}" : "]"
                    if nextSignificant(i + 1) == close {
                        // keep empty containers compact
                        var j = i + 1
                        while chars[j] != close { j += 1 }
                        out.append(close); i = j
                    } else { level += 1; newline() }
                case "}", "]": level -= 1; newline(); out.append(c)
                case ",": out.append(c); newline()
                case ":": out += ": "
                default: if !c.isWhitespace { out.append(c) }
                }
            }
            i += 1
        }
        return out
    }
}
