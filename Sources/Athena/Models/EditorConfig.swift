// EditorConfig.swift
// Athena — pure .editorconfig parsing, glob matching and save-time text transforms.
// Swift 6, strict concurrency.

import Foundation

/// Line ending a file is saved with.
enum LineEnding: String, Sendable, Equatable {
    case lf, crlf, cr

    var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// The subset of EditorConfig properties Athena honours. `nil` = unspecified.
struct EditorConfigSettings: Sendable, Equatable {
    var indentStyleSpaces: Bool?
    var indentSize: Int?
    var tabWidth: Int?
    var endOfLine: LineEnding?
    var trimTrailingWhitespace: Bool?
    var insertFinalNewline: Bool?
    /// Raw `charset` value, lowercased (e.g. "utf-8", "latin1"). Parsed but
    /// not applied: files are always written as UTF-8.
    var charset: String?

    static let empty = EditorConfigSettings()

    /// Per the spec `indent_size` falls back to `tab_width`.
    var effectiveIndentWidth: Int? { indentSize ?? tabWidth }

    /// True when the config says anything about indentation.
    var specifiesIndentation: Bool { indentStyleSpaces != nil || effectiveIndentWidth != nil }
}

/// One `[glob]` section of an .editorconfig file.
struct EditorConfigSection: Sendable, Equatable {
    var glob: String
    var properties: [String: String]
}

/// A parsed .editorconfig file.
struct EditorConfigFile: Sendable, Equatable {
    var isRoot: Bool
    var sections: [EditorConfigSection]

    // MARK: - Parsing

    static func parse(_ text: String) -> EditorConfigFile {
        var isRoot = false
        var sections: [EditorConfigSection] = []
        var current: Int?

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append(EditorConfigSection(glob: String(line.dropFirst().dropLast()), properties: [:]))
                current = sections.count - 1
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if let idx = current {
                sections[idx].properties[key] = value
            } else if key == "root" {
                isRoot = value.lowercased() == "true"
            }
        }
        return EditorConfigFile(isRoot: isRoot, sections: sections)
    }

    // MARK: - Resolution

    /// Properties from every matching section, later sections winning.
    /// `relativePath` is relative to the directory holding this file, `/`-separated.
    func properties(forRelativePath relativePath: String) -> [String: String] {
        var result: [String: String] = [:]
        for section in sections where EditorConfigGlob.matches(glob: section.glob, relativePath: relativePath) {
            for (k, v) in section.properties { result[k] = v }
        }
        return result
    }

    /// Effective settings for `filePath` (absolute): walks from the file's
    /// directory upward, nearest file winning, stopping at `root = true`.
    /// `readConfig` returns the text of `<dir>/.editorconfig` or nil; it is a
    /// closure so this stays pure and testable.
    static func resolve(filePath: String, readConfig: (String) -> String?) -> EditorConfigSettings {
        var layers: [[String: String]] = [] // nearest first
        var dir = (filePath as NSString).deletingLastPathComponent
        while true {
            if let text = readConfig(dir) {
                let parsed = parse(text)
                let prefix = dir == "/" ? "/" : dir + "/"
                let rel = filePath.hasPrefix(prefix)
                    ? String(filePath.dropFirst(prefix.count))
                    : (filePath as NSString).lastPathComponent
                layers.append(parsed.properties(forRelativePath: rel))
                if parsed.isRoot { break }
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        var merged: [String: String] = [:]
        for layer in layers.reversed() { for (k, v) in layer { merged[k] = v } }
        return settings(from: merged)
    }

    static func settings(from props: [String: String]) -> EditorConfigSettings {
        var s = EditorConfigSettings()
        func value(_ key: String) -> String? {
            guard let v = props[key]?.lowercased(), v != "unset" else { return nil }
            return v
        }
        func bool(_ key: String) -> Bool? {
            switch value(key) {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        switch value("indent_style") {
        case "space": s.indentStyleSpaces = true
        case "tab": s.indentStyleSpaces = false
        default: break
        }
        if let v = value("indent_size") {
            if v == "tab" {
                if s.indentStyleSpaces == nil { s.indentStyleSpaces = false }
            } else if let n = Int(v), n > 0 {
                s.indentSize = n
            }
        }
        if let v = value("tab_width"), let n = Int(v), n > 0 { s.tabWidth = n }
        switch value("end_of_line") {
        case "lf": s.endOfLine = .lf
        case "crlf": s.endOfLine = .crlf
        case "cr": s.endOfLine = .cr
        default: break
        }
        s.trimTrailingWhitespace = bool("trim_trailing_whitespace")
        s.insertFinalNewline = bool("insert_final_newline")
        s.charset = value("charset")
        return s
    }
}

// MARK: - Glob

/// EditorConfig glob matching: `*`, `**`, `?`, `[seq]`, `[!seq]`, `{a,b}`, `{n..m}`.
enum EditorConfigGlob {
    static func matches(glob: String, relativePath: String) -> Bool {
        var pattern = glob
        // A glob with no slash matches the basename at any depth.
        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        let body = translate(pattern)
        let full = anchored ? "^" + body + "$" : "^(?:.*/)?" + body + "$"
        guard let re = try? NSRegularExpression(pattern: full) else { return false }
        let range = NSRange(relativePath.startIndex..., in: relativePath)
        return re.firstMatch(in: relativePath, range: range) != nil
    }

    private static func translate(_ glob: String) -> String {
        let chars = Array(glob)
        var out = ""
        var i = 0
        var braceDepth = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    out += ".*"
                    i += 1
                } else {
                    out += "[^/]*"
                }
            case "?":
                out += "[^/]"
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]"), close > i + 1 {
                    var inner = String(chars[(i + 1)..<close])
                    if inner.hasPrefix("!") { inner = "^" + inner.dropFirst() }
                    inner = inner.replacingOccurrences(of: "\\", with: "\\\\")
                    out += "[" + inner + "]"
                    i = close
                } else {
                    out += "\\["
                }
            case "{":
                if let close = chars[(i + 1)...].firstIndex(of: "}") {
                    let inner = String(chars[(i + 1)..<close])
                    let parts = inner.components(separatedBy: "..")
                    if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), lo <= hi, hi - lo < 1000 {
                        out += "(?:" + (lo...hi).map(String.init).joined(separator: "|") + ")"
                        i = close
                    } else if !inner.contains(",") {
                        out += "\\{" + NSRegularExpression.escapedPattern(for: inner) + "\\}"
                        i = close
                    } else {
                        braceDepth += 1
                        out += "(?:"
                    }
                } else {
                    out += "\\{"
                }
            case "}":
                if braceDepth > 0 { braceDepth -= 1; out += ")" } else { out += "\\}" }
            case ",":
                out += braceDepth > 0 ? "|" : ","
            case "\\":
                if i + 1 < chars.count {
                    out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                    i += 1
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return out
    }
}

// MARK: - Save transforms

/// Text transforms applied when a file is written.
enum SaveTransforms {
    private static func isLineEnd(_ ch: Character) -> Bool { ch == "\n" || ch == "\r" || ch == "\r\n" }

    /// Removes spaces/tabs before each line end (LF, CRLF or CR) and at EOF.
    static func trimTrailingWhitespace(_ text: String) -> String {
        guard text.contains(where: { $0 == " " || $0 == "\t" }) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pending = ""
        for ch in text {
            if ch == " " || ch == "\t" { pending.append(ch); continue }
            if !isLineEnd(ch) { result += pending }
            pending = ""
            result.append(ch)
        }
        return result
    }

    /// Ensures a trailing line ending on non-empty text. Empty text stays
    /// empty; extra blank lines are not collapsed.
    static func ensureFinalNewline(_ text: String, ending: String = "\n") -> String {
        guard let last = text.last, !isLineEnd(last) else { return text }
        return text + ending
    }

    /// Converts every line ending to `ending`.
    static func normalizeLineEndings(_ text: String, to ending: LineEnding) -> String {
        guard text.contains(where: isLineEnd) else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text {
            if isLineEnd(ch) { out += ending.string } else { out.append(ch) }
        }
        return out
    }

    /// First line ending found, defaulting to LF.
    static func detectLineEnding(_ text: String) -> LineEnding {
        for ch in text {
            if ch == "\r\n" { return .crlf }
            if ch == "\n" { return .lf }
            if ch == "\r" { return .cr }
        }
        return .lf
    }

    /// Applies the save actions. EditorConfig values, when present, override
    /// the editor-wide toggles.
    static func apply(
        to text: String,
        trimSetting: Bool,
        finalNewlineSetting: Bool,
        config: EditorConfigSettings
    ) -> String {
        var t = text
        if config.trimTrailingWhitespace ?? trimSetting { t = trimTrailingWhitespace(t) }
        if let eol = config.endOfLine { t = normalizeLineEndings(t, to: eol) }
        if config.insertFinalNewline ?? finalNewlineSetting {
            t = ensureFinalNewline(t, ending: (config.endOfLine ?? detectLineEnding(t)).string)
        }
        return t
    }
}
