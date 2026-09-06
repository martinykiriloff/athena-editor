// DBExport.swift
// Athena — CSV / JSON serialisation of a fetched grid (table browser or query console).
// Swift 6, strict concurrency.

import Foundation

enum DBExportFormat: String, Sendable, CaseIterable {
    case csv, json

    var fileExtension: String { rawValue }
}

/// Pure formatters; the views hand the result to an `NSSavePanel`.
enum DBExport {

    static func render(_ format: DBExportFormat, columns: [DBColumn], rows: [DBRow]) -> String {
        switch format {
        case .csv:  return csv(columns: columns, rows: rows)
        case .json: return json(columns: columns, rows: rows)
        }
    }

    /// RFC 4180: comma-separated, CRLF line ends, fields quoted when they
    /// contain a comma, quote, or line break (embedded quotes doubled).
    /// NULL becomes an empty field.
    static func csv(columns: [DBColumn], rows: [DBRow]) -> String {
        var lines: [String] = [columns.map { csvField($0.name) }.joined(separator: ",")]
        for row in rows {
            lines.append(columns.map { csvField((row.values[$0.name] ?? .null).displayString) }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// An array of objects in column order; NULL → `null`, ints/doubles/
    /// bools as JSON scalars, everything else a string.
    static func json(columns: [DBColumn], rows: [DBRow]) -> String {
        var out = "[\n"
        for (i, row) in rows.enumerated() {
            let fields = columns.map { column -> String in
                "    \(jsonString(column.name)): \(jsonValue(row.values[column.name] ?? .null))"
            }
            out += "  {\n" + fields.joined(separator: ",\n") + "\n  }"
            out += i == rows.count - 1 ? "\n" : ",\n"
        }
        return out + "]\n"
    }

    // MARK: - Private helpers

    private static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func jsonValue(_ value: DBValue) -> String {
        switch value {
        case .null:          return "null"
        case .int(let i):    return String(i)
        case .double(let d): return d.isFinite ? String(d) : jsonString(String(d))
        case .bool(let b):   return b ? "true" : "false"
        case .text(let s):   return jsonString(s)
        }
    }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
