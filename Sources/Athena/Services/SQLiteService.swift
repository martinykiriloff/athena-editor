// SQLiteService.swift
// Athena — SQLite engine for the database browser, on GRDB (file-backed, no server).
// Swift 6, strict concurrency.

import Foundation
import GRDB

enum SQLiteServiceError: LocalizedError {
    case notConnected
    case noPrimaryKey
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to this database."
        case .noPrimaryKey: return "This table has no primary key, so editing is disabled."
        case .fileNotFound(let path): return "No SQLite file at \(path)."
        }
    }
}

actor SQLiteService: DBEngine {

    private var queues: [UUID: DatabaseQueue] = [:]

    // MARK: - Connection lifecycle

    /// Opens the file named by `config.database` (tilde-expanded). The file
    /// must already exist — creating databases by typo is not a feature.
    func connect(_ config: DBConnection) async throws {
        disconnect(config.id)
        let path = (config.database as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw SQLiteServiceError.fileNotFound(path)
        }
        let queue = try DatabaseQueue(path: path)
        try await queue.read { db in _ = try Row.fetchOne(db, sql: "SELECT 1") }
        queues[config.id] = queue
    }

    func disconnect(_ id: UUID) {
        queues[id] = nil
    }

    func isConnected(_ id: UUID) -> Bool {
        queues[id] != nil
    }

    // MARK: - Schema browsing

    func listTables(_ id: UUID) async throws -> [DBTableRef] {
        let queue = try queue(for: id)
        return try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """).map { DBTableRef(schema: "main", name: $0["name"]) }
        }
    }

    func columns(_ id: UUID, table: DBTableRef) async throws -> [DBColumn] {
        let queue = try queue(for: id)
        let name = table.name
        return try await queue.read { db in try Self.columns(db, tableName: name) }
    }

    func fetchRows(_ id: UUID, table: DBTableRef, limit: Int = 200) async throws -> DBTableData {
        let queue = try queue(for: id)
        return try await queue.read { db in
            let columns = try Self.columns(db, tableName: table.name)
            let statement = try db.makeStatement(sql: "SELECT * FROM \(table.qualifiedSQL) LIMIT \(limit)")
            let (rows, _) = try Self.rows(from: statement, limit: limit)
            return DBTableData(table: table, columns: columns, rows: rows, isComplete: rows.count < limit)
        }
    }

    // MARK: - Editing

    func updateCell(_ id: UUID, table: DBTableRef, column: String,
                    newValue: DBValue, primaryKeyValues: [String: DBValue]) async throws {
        guard !primaryKeyValues.isEmpty else { throw SQLiteServiceError.noPrimaryKey }
        let queue = try queue(for: id)
        var arguments: [(any DatabaseValueConvertible)?] = [Self.encode(newValue)]
        var clauses: [String] = []
        for (pkColumn, pkValue) in primaryKeyValues.sorted(by: { $0.key < $1.key }) {
            arguments.append(Self.encode(pkValue))
            clauses.append("\(DBTableRef.quoted(pkColumn)) = ?")
        }
        let sql = "UPDATE \(table.qualifiedSQL) SET \(DBTableRef.quoted(column)) = ? WHERE \(clauses.joined(separator: " AND "))"
        let args = StatementArguments(arguments)
        try await queue.write { db in try db.execute(sql: sql, arguments: args) }
    }

    // MARK: - Query console

    func runQuery(_ id: UUID, sql: String, limit: Int = 500) async throws -> DBQueryResult {
        let queue = try queue(for: id)
        let start = ContinuousClock.now
        return try await queue.write { db in
            let statement = try db.makeStatement(sql: sql)
            if statement.columnCount > 0 {
                let (rows, truncated) = try Self.rows(from: statement, limit: limit)
                let columns = DBQueryResult.uniqueColumnNames(statement.columnNames)
                    .map { DBColumn(name: $0, dataTypeName: "", isPrimaryKey: false) }
                return DBQueryResult(columns: columns, rows: rows, affectedRows: nil,
                                     elapsed: start.duration(to: .now), isTruncated: truncated)
            }
            try statement.execute()
            let affected = DBQueryResult.isDataModifying(sql) ? db.changesCount : nil
            return DBQueryResult(columns: [], rows: [], affectedRows: affected,
                                 elapsed: start.duration(to: .now), isTruncated: false)
        }
    }

    // MARK: - Private helpers

    private func queue(for id: UUID) throws -> DatabaseQueue {
        guard let queue = queues[id] else { throw SQLiteServiceError.notConnected }
        return queue
    }

    private static func columns(_ db: Database, tableName: String) throws -> [DBColumn] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(DBTableRef.quoted(tableName)))").map { row in
            DBColumn(name: row["name"], dataTypeName: row["type"] ?? "", isPrimaryKey: (row["pk"] as Int? ?? 0) > 0)
        }
    }

    /// Reads up to `limit` rows; reports whether more were available.
    private static func rows(from statement: Statement, limit: Int) throws -> ([DBRow], Bool) {
        let names = DBQueryResult.uniqueColumnNames(statement.columnNames)
        var rows: [DBRow] = []
        let cursor = try Row.fetchCursor(statement)
        var truncated = false
        while let row = try cursor.next() {
            if rows.count >= limit { truncated = true; break }
            var values: [String: DBValue] = [:]
            for (i, name) in names.enumerated() {
                let value: DatabaseValue = row[i]
                values[name] = decode(value)
            }
            rows.append(DBRow(id: rows.count, values: values))
        }
        return (rows, truncated)
    }

    static func decode(_ value: DatabaseValue) -> DBValue {
        switch value.storage {
        case .null:            return .null
        case .int64(let i):    return .int(i)
        case .double(let d):   return .double(d)
        case .string(let s):   return .text(s)
        case .blob(let data):  return .text("<blob \(data.count) bytes>")
        }
    }

    static func encode(_ value: DBValue) -> (any DatabaseValueConvertible)? {
        switch value {
        case .text(let s):   return s
        case .int(let i):    return i
        case .double(let d): return d
        case .bool(let b):   return b ? 1 : 0
        case .null:          return nil
        }
    }
}
