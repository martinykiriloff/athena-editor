// DBEngine.swift
// Athena — the per-engine contract behind the database browser and query console.
// Swift 6, strict concurrency.

import Foundation

/// One database engine (PostgreSQL, SQLite, …). Each conformer is an actor
/// owning its live connections keyed by `DBConnection.id`; `AppState` picks
/// the engine from `DBConnection.type` and never touches drivers directly.
/// Adding an engine means one new actor conforming to this, nothing in the UI.
protocol DBEngine: Actor {
    func connect(_ config: DBConnection) async throws
    func disconnect(_ id: UUID) async
    func isConnected(_ id: UUID) async -> Bool

    func listTables(_ id: UUID) async throws -> [DBTableRef]
    func columns(_ id: UUID, table: DBTableRef) async throws -> [DBColumn]
    func fetchRows(_ id: UUID, table: DBTableRef, limit: Int) async throws -> DBTableData
    func updateCell(_ id: UUID, table: DBTableRef, column: String,
                    newValue: DBValue, primaryKeyValues: [String: DBValue]) async throws

    /// Runs one SQL statement as typed. Row-returning statements are capped
    /// at `limit` rows (with `isTruncated` set); others report affected rows.
    func runQuery(_ id: UUID, sql: String, limit: Int) async throws -> DBQueryResult
}
