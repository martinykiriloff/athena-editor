// VSCodeThemeImporter.swift
// Athena — parses VS Code theme JSON files and maps a useful subset of
// their `colors`/`tokenColors` onto Athena's `EditorTheme` shape
// (plan.md item 27, "G4"). Pure, no I/O — callers read the file and hand
// the raw JSON string in.
// Swift 6, strict concurrency.

import Foundation

// MARK: - VSCodeThemeImportError

enum VSCodeThemeImportError: Error, Equatable {
    /// Decoding failed outright — not JSON (even after JSONC cleanup), or
    /// not a JSON object at all.
    case invalidJSON
    /// Decoded fine, but neither `colors` nor `tokenColors` was present —
    /// almost certainly not a VS Code theme file (e.g. a `package.json`).
    case emptyTheme
}

// MARK: - VSCodeThemeImporter

/// **Strictness choice**: real-world VS Code theme files are occasionally
/// authored with JSONC-style leniency (`//` line comments, trailing commas)
/// despite carrying a `.json` extension. This importer accepts that
/// leniency — `stripJSONCArtifacts` removes comments and trailing commas
/// before decoding — rather than requiring byte-strict JSON, since rejecting
/// a theme copied from a GitHub gist or an in-progress extension would be a
/// worse experience than a few extra lines of preprocessing.
enum VSCodeThemeImporter {

    // MARK: Public API

    /// - Parameters:
    ///   - jsonString: raw theme file contents.
    ///   - id: the id to assign the resulting `EditorTheme` — the caller
    ///     (`AppState.importVSCodeTheme`) is responsible for making this
    ///     unique against existing built-in/custom theme ids.
    ///   - fallback: base theme supplying every color this file doesn't
    ///     specify. Defaults to the closest built-in theme by the file's
    ///     own declared `"type"` (`"light"` → `.githubLight`, anything else
    ///     — `"dark"`, `"hc"`, or missing — → `.darcula`).
    static func parse(_ jsonString: String, id: String, fallback: EditorTheme? = nil) throws -> EditorTheme {
        let cleaned = stripJSONCArtifacts(jsonString)
        guard let data = cleaned.data(using: .utf8) else {
            throw VSCodeThemeImportError.invalidJSON
        }

        let file: VSCodeThemeFile
        do {
            file = try JSONDecoder().decode(VSCodeThemeFile.self, from: data)
        } catch {
            throw VSCodeThemeImportError.invalidJSON
        }

        guard file.colors != nil || file.tokenColors != nil else {
            throw VSCodeThemeImportError.emptyTheme
        }

        let base = fallback ?? (file.type?.lowercased() == "light" ? EditorTheme.githubLight : EditorTheme.darcula)

        var overrides = mapColors(file.colors ?? [:])
        for (field, hex) in mapTokenColors(file.tokenColors ?? []) where overrides[field] == nil {
            overrides[field] = hex
        }

        let trimmedName = file.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmedName.isEmpty ? id : trimmedName

        return EditorTheme(id: id, name: name, base: base, overrides: overrides)
    }

    // MARK: - JSON model

    private struct VSCodeThemeFile: Decodable {
        let name: String?
        let type: String?
        let colors: [String: String]?
        let tokenColors: [VSCodeTokenColorEntry]?
    }

    private struct VSCodeTokenColorEntry: Decodable {
        let scope: VSCodeScopeValue?
        let settings: VSCodeTokenSettings?
    }

    /// `scope` is either a single TextMate scope selector string (optionally
    /// comma-separated) or an array of them.
    private enum VSCodeScopeValue: Decodable {
        case single(String)
        case list([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([String].self) {
                self = .list(list)
            } else {
                self = .single((try? container.decode(String.self)) ?? "")
            }
        }

        var scopes: [String] {
            let raw: [String]
            switch self {
            case .single(let s): raw = [s]
            case .list(let l):   raw = l
            }
            return raw
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    private struct VSCodeTokenSettings: Decodable {
        let foreground: String?
        let fontStyle: String?
    }

    // MARK: - UI chrome (`colors`) mapping

    /// Athena field ← first matching VS Code `colors` key present.
    private static let colorKeyMap: [(EditorTheme.Field, [String])] = [
        (.background,        ["editor.background"]),
        (.foreground,        ["editor.foreground"]),
        (.cursor,             ["editorCursor.foreground"]),
        (.selection,          ["editor.selectionBackground"]),
        (.lineHighlight,      ["editor.lineHighlightBackground"]),
        (.whitespace,         ["editorWhitespace.foreground"]),
        (.diagnosticError,    ["editorError.foreground"]),
        (.diagnosticWarning,  ["editorWarning.foreground"]),
        (.diagnosticInfo,     ["editorInfo.foreground"]),
        (.diffAdded,          ["diffEditor.insertedTextBackground", "gitDecoration.addedResourceForeground"]),
        (.diffRemoved,        ["diffEditor.removedTextBackground", "gitDecoration.deletedResourceForeground"]),
        (.diffModified,       ["gitDecoration.modifiedResourceForeground"]),
    ]

    private static func mapColors(_ colors: [String: String]) -> [EditorTheme.Field: UInt32] {
        var result: [EditorTheme.Field: UInt32] = [:]
        for (field, keys) in colorKeyMap {
            for key in keys {
                if let raw = colors[key], let hex = parseHexColor(raw) {
                    result[field] = hex
                    break
                }
            }
        }
        return result
    }

    // MARK: - Syntax (`tokenColors`) mapping

    /// Athena field ← TextMate scope substrings that reasonably indicate it,
    /// checked in this order (most specific first) so e.g. a
    /// `"entity.name.function"` scope is caught by `.function` before the
    /// looser `.keyword` bucket ever sees it. Doesn't need to be exhaustive
    /// — just cover the common, high-value cases well.
    private static let scopeFieldPriority: [(EditorTheme.Field, [String])] = [
        (.comment,    ["comment"]),
        (.string,     ["string"]),
        (.number,     ["constant.numeric", "numeric"]),
        (.function,   ["entity.name.function", "support.function", "meta.function-call"]),
        (.type,       ["entity.name.type", "entity.name.class", "support.type", "support.class",
                        "entity.name.tag", "entity.other.inherited-class"]),
        (.annotation, ["entity.name.annotation", "punctuation.definition.annotation",
                        "storage.type.annotation", "meta.decorator"]),
        (.keyword,    ["keyword", "storage"]),
    ]

    /// First `tokenColors` entry whose scope matches a field wins that
    /// field — VS Code theme files generally list broader scopes first and
    /// more specific overrides later, so "first match" lands on a
    /// reasonable representative color per category without needing full
    /// TextMate scope-specificity resolution.
    private static func mapTokenColors(_ entries: [VSCodeTokenColorEntry]) -> [EditorTheme.Field: UInt32] {
        var result: [EditorTheme.Field: UInt32] = [:]
        for entry in entries {
            guard let scopes = entry.scope?.scopes, !scopes.isEmpty,
                  let foreground = entry.settings?.foreground,
                  let hex = parseHexColor(foreground)
            else { continue }

            for scope in scopes {
                let lower = scope.lowercased()
                for (field, substrings) in scopeFieldPriority {
                    guard result[field] == nil else { continue }
                    if substrings.contains(where: { lower.contains($0) }) {
                        result[field] = hex
                    }
                }
            }
        }
        return result
    }

    // MARK: - Hex color parsing

    /// Accepts `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA` (alpha is dropped —
    /// `EditorTheme` colors are always opaque).
    private static func parseHexColor(_ raw: String) -> UInt32? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()

        switch s.count {
        case 3, 4:
            // Shorthand — each character doubles; keep only the first 6
            // resulting digits (RGB), dropping a 4th shorthand alpha digit.
            let expanded = s.flatMap { [$0, $0] }
            s = String(expanded.prefix(6))
        case 6:
            break
        case 8:
            s = String(s.prefix(6))
        default:
            return nil
        }

        return UInt32(s, radix: 16)
    }

    // MARK: - JSONC leniency

    /// Strips `//` and `/* */` comments (outside string literals) and
    /// trailing commas before `}`/`]`, so a hand-edited or gist-copied
    /// theme file with JSONC-style leniency still decodes.
    static func stripJSONCArtifacts(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var inString = false
        var escaped = false
        let chars = Array(text)
        var idx = 0

        while idx < chars.count {
            let c = chars[idx]

            if inString {
                result.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                idx += 1
                continue
            }

            if c == "\"" {
                inString = true
                result.append(c)
                idx += 1
                continue
            }

            if c == "/", idx + 1 < chars.count, chars[idx + 1] == "/" {
                while idx < chars.count, chars[idx] != "\n" { idx += 1 }
                continue
            }

            if c == "/", idx + 1 < chars.count, chars[idx + 1] == "*" {
                idx += 2
                while idx + 1 < chars.count, !(chars[idx] == "*" && chars[idx + 1] == "/") { idx += 1 }
                idx = min(idx + 2, chars.count)
                continue
            }

            result.append(c)
            idx += 1
        }

        guard let regex = try? NSRegularExpression(pattern: ",(\\s*[}\\]])") else { return result }
        let range = NSRange(result.startIndex..., in: result)
        return regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
    }
}
