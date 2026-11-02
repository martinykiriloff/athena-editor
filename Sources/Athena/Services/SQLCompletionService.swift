// SQLCompletionService.swift
// Athena — schema-aware SQL completions (tables, columns, aliases, keywords) and statement splitting for the query editor.
// Swift 6, strict concurrency.

import Foundation

// MARK: - Schema

/// A connection's tables and their columns, as fed to SQL completion.
struct SQLSchema: Sendable, Equatable {
    var tables: [DBTableRef] = []
    /// Columns keyed by table name (unqualified, lowercased).
    var columns: [String: [DBColumn]] = [:]

    static func == (l: SQLSchema, r: SQLSchema) -> Bool { l.tables == r.tables && l.columns == r.columns }
}

// MARK: - Provider

actor SQLCompletionService {
    private var schema = SQLSchema()

    func setSchema(_ new: SQLSchema) { schema = new }

    /// Completions at a 1-based `line` / `col` of `text`.
    func complete(text: String, line: Int, col: Int) -> [CompletionItem] {
        SQLCompletion.items(text: text, line: line, col: col, schema: schema)
    }
}

// MARK: - Pure logic

enum SQLCompletion {

    static let keywords = ["SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "IN", "LIKE", "BETWEEN", "JOIN",
                           "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "ON", "GROUP BY", "ORDER BY", "HAVING", "LIMIT",
                           "OFFSET", "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "CREATE TABLE",
                           "DROP TABLE", "ALTER TABLE", "DISTINCT", "AS", "COUNT", "SUM", "AVG", "MIN", "MAX",
                           "ASC", "DESC", "UNION", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END"]

    private static let tableKeywords: Set<String> = ["from", "join", "into", "update", "table"]

    static func items(text: String, line: Int, col: Int, schema: SQLSchema) -> [CompletionItem] {
        let before = textBeforeCursor(text, line: line, col: col)
        let prefix = trailingIdentifier(before)
        let head = String(before.dropLast(prefix.count))

        // `alias.` / `table.` → that table's columns.
        if prefix.contains(".") || head.hasSuffix(".") {
            let qualifier: String
            if let dot = prefix.lastIndex(of: ".") {
                qualifier = String(prefix[..<dot])
            } else {
                qualifier = trailingIdentifier(String(head.dropLast()))
            }
            let table = resolveTable(qualifier: qualifier, in: text, schema: schema)
            return columnItems(forTable: table, schema: schema)
        }

        let previous = previousWord(head).lowercased()
        if tableKeywords.contains(previous) {
            return schema.tables.map(tableItem)
        }

        var out: [CompletionItem] = []
        for t in referencedTables(in: text, schema: schema) { out += columnItems(forTable: t, schema: schema) }
        out += schema.tables.map(tableItem)
        out += keywords.map { CompletionItem(label: $0, kind: "keyword", detail: nil, insertText: $0) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.label + $0.kind).inserted }
    }

    // MARK: Text helpers

    static func textBeforeCursor(_ text: String, line: Int, col: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return text }
        let current = String(lines[line - 1].prefix(max(0, col - 1)))
        return (lines[..<(line - 1)] + [current]).joined(separator: "\n")
    }

    static func trailingIdentifier(_ s: String) -> String {
        String(s.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }.reversed())
    }

    static func previousWord(_ head: String) -> String {
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.reversed().prefix { $0.isLetter || $0 == "_" }.reversed())
    }

    /// `(table, alias?)` pairs from `FROM x [AS] a` / `JOIN y b`.
    static func tableReferences(in text: String) -> [(table: String, alias: String?)] {
        let pattern = #"(?i)\b(?:from|join|update|into)\s+("?[\w]+"?(?:\."?[\w]+"?)?)(?:\s+(?:as\s+)?([A-Za-z_]\w*))?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let reserved: Set<String> = ["where", "on", "join", "left", "right", "inner", "outer", "group", "order", "limit",
                                     "set", "values", "union", "having", "cross", "full", "using", "select"]
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let table = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\"", with: "")
            var alias: String?
            if m.range(at: 2).location != NSNotFound {
                let a = ns.substring(with: m.range(at: 2))
                if !reserved.contains(a.lowercased()) { alias = a }
            }
            return (table, alias)
        }
    }

    static func resolveTable(qualifier: String, in text: String, schema: SQLSchema) -> String? {
        let q = qualifier.lowercased()
        for ref in tableReferences(in: text) where ref.alias?.lowercased() == q { return unqualified(ref.table) }
        if schema.columns[q] != nil { return q }
        return nil
    }

    static func referencedTables(in text: String, schema: SQLSchema) -> [String] {
        tableReferences(in: text).map { unqualified($0.table) }.filter { schema.columns[$0] != nil }
    }

    private static func unqualified(_ name: String) -> String {
        (name.split(separator: ".").last.map(String.init) ?? name).lowercased()
    }

    // MARK: Items

    private static func tableItem(_ t: DBTableRef) -> CompletionItem {
        CompletionItem(label: t.name, kind: "class", detail: t.schema, insertText: t.name)
    }

    private static func columnItems(forTable table: String?, schema: SQLSchema) -> [CompletionItem] {
        guard let table, let cols = schema.columns[table] else { return [] }
        return cols.map {
            CompletionItem(label: $0.name, kind: "field", detail: $0.dataTypeName + ($0.isPrimaryKey ? " · PK" : ""),
                           insertText: $0.name)
        }
    }
}

// MARK: - Statement splitting

enum SQLStatementSplitter {

    /// All statements as `(text, range)` split on `;` outside strings,
    /// quoted identifiers and comments. Ranges are UTF-16 offsets into `sql`.
    static func statements(in sql: String) -> [(text: String, range: NSRange)] {
        let ns = sql as NSString
        var result: [(String, NSRange)] = []
        var start = 0
        var i = 0
        var quote: unichar?
        while i < ns.length {
            let c = ns.character(at: i)
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 0x27 || c == 0x22 || c == 0x60 {           // ' " `
                quote = c
            } else if c == 0x2D, i + 1 < ns.length, ns.character(at: i + 1) == 0x2D {   // -- comment
                while i < ns.length, ns.character(at: i) != 0x0A { i += 1 }
                continue
            } else if c == 0x2F, i + 1 < ns.length, ns.character(at: i + 1) == 0x2A {   // /* comment */
                i += 2
                while i + 1 < ns.length, !(ns.character(at: i) == 0x2A && ns.character(at: i + 1) == 0x2F) { i += 1 }
                i += 2
                continue
            } else if c == 0x3B {                                       // ;
                append(ns, from: start, to: i, into: &result)
                start = i + 1
            }
            i += 1
        }
        append(ns, from: start, to: ns.length, into: &result)
        return result
    }

    private static func append(_ ns: NSString, from: Int, to: Int, into result: inout [(String, NSRange)]) {
        guard to > from else { return }
        let range = NSRange(location: from, length: to - from)
        let text = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { result.append((text, range)) }
    }

    /// The statement the caret (UTF-16 `offset`) is in; on whitespace between
    /// statements, the one before it.
    static func statement(in sql: String, atOffset offset: Int) -> String? {
        let all = statements(in: sql)
        if let hit = all.first(where: { NSLocationInRange(offset, NSRange(location: $0.range.location, length: $0.range.length + 2)) }) {
            return hit.text
        }
        return all.last(where: { $0.range.location <= offset })?.text ?? all.first?.text
    }
}

// MARK: - History

enum SQLHistory {
    static let maxEntries = 200

    /// Newest first; an identical consecutive statement on the same connection is not repeated.
    static func adding(_ entry: SQLHistoryEntry, to list: [SQLHistoryEntry]) -> [SQLHistoryEntry] {
        let sql = entry.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return list }
        var result = list
        if let first = result.first, first.sql == sql, first.connectionName == entry.connectionName { return result }
        var e = entry
        e.sql = sql
        result.insert(e, at: 0)
        return Array(result.prefix(maxEntries))
    }
}
