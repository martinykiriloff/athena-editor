// PostgresService.swift
// Athena — manages PostgreSQL connections and query execution for the DB browser.
// Swift 6, strict concurrency.

import Foundation
import Logging
import PostgresNIO

enum PostgresServiceError: LocalizedError {
    case notConnected
    case noPrimaryKey

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to this database."
        case .noPrimaryKey: return "This table has no primary key, so editing is disabled."
        }
    }
}

actor PostgresService {

    // MARK: State

    /// One live connection: the client plus the `Task` running its required
    /// background event loop (`PostgresClient.run()`) — cancelling that task
    /// is how a `PostgresClient` shuts down.
    private struct Connection {
        let client: PostgresClient
        let runTask: Task<Void, Never>
    }

    private var connections: [UUID: Connection] = [:]
    private let logger = Logger(label: "com.athena.postgres")

    // MARK: - Connection lifecycle

    /// Opens a connection for `config`, replacing any existing one for the
    /// same id, and verifies it with a trivial round-trip query before
    /// returning — callers see a real error immediately rather than only on
    /// first browse.
    func connect(_ config: DBConnection) async throws {
        disconnect(config.id)

        let clientConfig = PostgresClient.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password.isEmpty ? nil : config.password,
            database: config.database.isEmpty ? config.username : config.database,
            tls: .disable
        )
        let client = PostgresClient(configuration: clientConfig)
        let runTask = Task { await client.run() }
        connections[config.id] = Connection(client: client, runTask: runTask)

        do {
            _ = try await client.query("SELECT 1", logger: logger)
        } catch {
            disconnect(config.id)
            throw error
        }
    }

    /// Closes the connection for `id`, if one is open. Safe to call when none is.
    func disconnect(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.runTask.cancel()
    }

    func isConnected(_ id: UUID) -> Bool {
        connections[id] != nil
    }

    // MARK: - Schema browsing

    /// Every user table across every non-system schema, alphabetically.
    func listTables(_ id: UUID) async throws -> [DBTableRef] {
        let client = try client(for: id)
        let rows = try await client.query(
            """
            SELECT table_schema, table_name FROM information_schema.tables
            WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
            ORDER BY table_schema, table_name
            """,
            logger: logger
        )

        var tables: [DBTableRef] = []
        for try await row in rows {
            let (schema, name) = try row.decode((String, String).self)
            tables.append(DBTableRef(schema: schema, name: name))
        }
        return tables
    }

    /// `table`'s columns in declared order, each flagged as primary-key or not.
    func columns(_ id: UUID, table: DBTableRef) async throws -> [DBColumn] {
        let client = try client(for: id)

        let primaryKeys = try await primaryKeyColumns(id, table: table)

        let rows = try await client.query(
            """
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE table_schema = \(table.schema) AND table_name = \(table.name)
            ORDER BY ordinal_position
            """,
            logger: logger
        )

        var columns: [DBColumn] = []
        for try await row in rows {
            let (name, dataType) = try row.decode((String, String).self)
            columns.append(DBColumn(name: name, dataTypeName: dataType, isPrimaryKey: primaryKeys.contains(name)))
        }
        return columns
    }

    /// Fetches up to `limit` rows of `table`, along with its column shape.
    func fetchRows(_ id: UUID, table: DBTableRef, limit: Int = 200) async throws -> DBTableData {
        let client = try client(for: id)
        let tableColumns = try await columns(id, table: table)

        let query = PostgresQuery(unsafeSQL: "SELECT * FROM \(table.qualifiedSQL) LIMIT \(limit)")
        let result = try await client.query(query, logger: logger)

        var rows: [DBRow] = []
        var index = 0
        for try await row in result {
            var values: [String: DBValue] = [:]
            for (cell, metadata) in zip(row, result.columns) {
                values[metadata.name] = Self.decode(cell, dataType: metadata.dataType)
            }
            rows.append(DBRow(id: index, values: values))
            index += 1
        }
        return DBTableData(table: table, columns: tableColumns, rows: rows, isComplete: rows.count < limit)
    }

    // MARK: - Editing

    /// Updates one cell, targeting the exact row via its primary-key
    /// values (captured at fetch time) rather than its position in the grid,
    /// so an edit is correct even if the grid has since re-sorted or the
    /// underlying table has changed. Throws `noPrimaryKey` if `table` has
    /// none — there is no other reliable way to address a single row.
    func updateCell(
        _ id: UUID,
        table: DBTableRef,
        column: String,
        newValue: DBValue,
        primaryKeyValues: [String: DBValue]
    ) async throws {
        guard !primaryKeyValues.isEmpty else { throw PostgresServiceError.noPrimaryKey }
        let client = try client(for: id)

        var binds = PostgresBindings(capacity: primaryKeyValues.count + 1)
        binds.append(newValue)

        var whereClauses: [String] = []
        for (pkColumn, pkValue) in primaryKeyValues.sorted(by: { $0.key < $1.key }) {
            binds.append(pkValue)
            whereClauses.append("\(DBTableRef.quoted(pkColumn)) = $\(binds.count)")
        }

        let sql = """
            UPDATE \(table.qualifiedSQL)
            SET \(DBTableRef.quoted(column)) = $1
            WHERE \(whereClauses.joined(separator: " AND "))
            """
        try await client.query(PostgresQuery(unsafeSQL: sql, binds: binds), logger: logger)
    }

    // MARK: - Private helpers

    private func client(for id: UUID) throws -> PostgresClient {
        guard let connection = connections[id] else { throw PostgresServiceError.notConnected }
        return connection.client
    }

    private func primaryKeyColumns(_ id: UUID, table: DBTableRef) async throws -> Set<String> {
        let client = try client(for: id)
        let rows = try await client.query(
            """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = \(table.schema) AND tc.table_name = \(table.name)
            """,
            logger: logger
        )
        var names: Set<String> = []
        for try await row in rows {
            names.insert(try row.decode(String.self))
        }
        return names
    }

    /// Decodes one cell into a display-friendly `DBValue` based on its wire
    /// data type. Anything not explicitly listed falls back to a string
    /// decode — this covers dates, UUIDs, JSON, arrays, etc. well enough for
    /// a browsing/editing grid without a case for every Postgres type.
    private static func decode(_ cell: PostgresCell, dataType: PostgresDataType) -> DBValue {
        if cell.bytes == nil { return .null }
        switch dataType {
        case .bool:
            return (try? cell.decode(Bool.self)).map(DBValue.bool) ?? .null
        case .int2:
            return (try? cell.decode(Int16.self)).map { .int(Int64($0)) } ?? .null
        case .int4:
            return (try? cell.decode(Int32.self)).map { .int(Int64($0)) } ?? .null
        case .int8:
            return (try? cell.decode(Int64.self)).map(DBValue.int) ?? .null
        case .float4:
            return (try? cell.decode(Float.self)).map { .double(Double($0)) } ?? .null
        case .float8, .numeric:
            return (try? cell.decode(Double.self)).map(DBValue.double) ?? .null
        case .timestamp, .timestamptz, .date:
            // These are wire-encoded as binary (not text), so decoding
            // straight to `String` — the `default` fallback below — reads
            // the raw bytes as text and produces garbage, not a date.
            // `Date` is what PostgresNIO actually supports decoding these
            // to; format it back to a readable string for display/editing.
            return (try? cell.decode(Date.self)).map { .text($0.ISO8601Format()) } ?? .null
        default:
            return (try? cell.decode(String.self)).map(DBValue.text) ?? .text("<unsupported>")
        }
    }
}

private extension PostgresBindings {
    mutating func append(_ value: DBValue) {
        switch value {
        case .text(let s):   self.append(s)
        case .int(let i):    self.append(i)
        case .double(let d): self.append(d)
        case .bool(let b):   self.append(b)
        case .null:          self.appendNull()
        }
    }
}
