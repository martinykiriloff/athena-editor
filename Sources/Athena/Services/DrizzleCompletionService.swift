// DrizzleCompletionService.swift
// Athena — Drizzle ORM static completions + schema-aware dynamic completions.
// Swift 6, strict concurrency.

import Foundation

// MARK: - DrizzleCompletionService

actor DrizzleCompletionService {

    // MARK: - Public API

    /// Returns Drizzle-specific completions for the given cursor position.
    /// Returns an empty array when the file has no drizzle-orm imports.
    func complete(text: String, line: Int, col: Int, fileURL: URL) -> [CompletionItem] {
        guard isDrizzleContext(text: text, fileURL: fileURL) else { return [] }
        let lineStr = lineAt(in: text, line: line)
        let prefix  = String(lineStr.prefix(max(0, col - 1)))
        return completions(forPrefix: prefix, text: text)
    }

    // MARK: - Context detection

    private func isDrizzleContext(text: String, fileURL: URL) -> Bool {
        let name = fileURL.lastPathComponent
        if name == "schema.ts" || name == "schema.js" || name == "schema.tsx" { return true }
        return text.contains("from 'drizzle-orm") || text.contains("from \"drizzle-orm")
    }

    private func lineAt(in text: String, line: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        guard line > 0, line <= lines.count else { return "" }
        return lines[line - 1]
    }

    // MARK: - Completion dispatch

    private func completions(forPrefix prefix: String, text: String) -> [CompletionItem] {
        if prefix.hasSuffix("db.") || prefix.hasSuffix("db?.") {
            return queryBuilderItems
        }
        if isSQLExpressionContext(prefix) {
            return operatorItems + sqlFunctionItems
        }
        if isColumnDefContext(prefix) {
            return columnTypeItems
        }
        if prefix.hasSuffix("relations(") || prefix.contains("relations:") {
            return relationItems
        }
        // Generic drizzle context — show the most-used items
        return queryBuilderItems + operatorItems
    }

    private func isSQLExpressionContext(_ prefix: String) -> Bool {
        [".where(", ".having(", ".set(", ".values(", "and(", "or("].contains(where: prefix.contains)
    }

    private func isColumnDefContext(_ prefix: String) -> Bool {
        ["pgTable(", "mysqlTable(", "sqliteTable("].contains(where: prefix.contains)
    }

    // MARK: - Static completion items

    private let queryBuilderItems: [CompletionItem] = [
        CompletionItem(label: "select",        kind: "method",   detail: "SELECT columns",        insertText: "select()"),
        CompletionItem(label: "selectDistinct",kind: "method",   detail: "SELECT DISTINCT",       insertText: "selectDistinct()"),
        CompletionItem(label: "from",          kind: "method",   detail: "FROM table",            insertText: "from()"),
        CompletionItem(label: "where",         kind: "method",   detail: "WHERE condition",       insertText: "where()"),
        CompletionItem(label: "orderBy",       kind: "method",   detail: "ORDER BY",              insertText: "orderBy()"),
        CompletionItem(label: "limit",         kind: "method",   detail: "LIMIT n",               insertText: "limit()"),
        CompletionItem(label: "offset",        kind: "method",   detail: "OFFSET n",              insertText: "offset()"),
        CompletionItem(label: "groupBy",       kind: "method",   detail: "GROUP BY",              insertText: "groupBy()"),
        CompletionItem(label: "having",        kind: "method",   detail: "HAVING condition",      insertText: "having()"),
        CompletionItem(label: "innerJoin",     kind: "method",   detail: "INNER JOIN",            insertText: "innerJoin(, eq(, ))"),
        CompletionItem(label: "leftJoin",      kind: "method",   detail: "LEFT JOIN",             insertText: "leftJoin(, eq(, ))"),
        CompletionItem(label: "rightJoin",     kind: "method",   detail: "RIGHT JOIN",            insertText: "rightJoin(, eq(, ))"),
        CompletionItem(label: "fullJoin",      kind: "method",   detail: "FULL JOIN",             insertText: "fullJoin(, eq(, ))"),
        CompletionItem(label: "insert",        kind: "method",   detail: "INSERT INTO",           insertText: "insert(into: )"),
        CompletionItem(label: "values",        kind: "method",   detail: ".values({ … })",        insertText: "values({ })"),
        CompletionItem(label: "update",        kind: "method",   detail: "UPDATE table",          insertText: "update()"),
        CompletionItem(label: "set",           kind: "method",   detail: ".set({ col: val })",    insertText: "set({ })"),
        CompletionItem(label: "delete",        kind: "method",   detail: "DELETE FROM",           insertText: "delete()"),
        CompletionItem(label: "onConflictDoNothing", kind: "method", detail: "ON CONFLICT DO NOTHING", insertText: "onConflictDoNothing()"),
        CompletionItem(label: "onConflictDoUpdate",  kind: "method", detail: "ON CONFLICT DO UPDATE",  insertText: "onConflictDoUpdate({ target: , set: {} })"),
        CompletionItem(label: "query",         kind: "method",   detail: "Relational query API",  insertText: "query"),
        CompletionItem(label: "transaction",   kind: "method",   detail: "Begin transaction",     insertText: "transaction(async (tx) => {\n\t\n})"),
        CompletionItem(label: "execute",       kind: "method",   detail: "Execute raw SQL",       insertText: "execute(sql``)"),
        CompletionItem(label: "with",          kind: "method",   detail: "WITH (relational with)", insertText: "with({ })"),
        CompletionItem(label: "returning",     kind: "method",   detail: "RETURNING columns",     insertText: "returning()"),
    ]

    private let operatorItems: [CompletionItem] = [
        CompletionItem(label: "eq",          kind: "function", detail: "=",               insertText: "eq(, )"),
        CompletionItem(label: "ne",          kind: "function", detail: "!=",              insertText: "ne(, )"),
        CompletionItem(label: "lt",          kind: "function", detail: "<",               insertText: "lt(, )"),
        CompletionItem(label: "lte",         kind: "function", detail: "<=",              insertText: "lte(, )"),
        CompletionItem(label: "gt",          kind: "function", detail: ">",               insertText: "gt(, )"),
        CompletionItem(label: "gte",         kind: "function", detail: ">=",              insertText: "gte(, )"),
        CompletionItem(label: "and",         kind: "function", detail: "AND",             insertText: "and(, )"),
        CompletionItem(label: "or",          kind: "function", detail: "OR",              insertText: "or(, )"),
        CompletionItem(label: "not",         kind: "function", detail: "NOT",             insertText: "not()"),
        CompletionItem(label: "like",        kind: "function", detail: "LIKE '%…%'",      insertText: "like(, '%')"),
        CompletionItem(label: "ilike",       kind: "function", detail: "ILIKE '%…%'",     insertText: "ilike(, '%')"),
        CompletionItem(label: "notLike",     kind: "function", detail: "NOT LIKE",        insertText: "notLike(, '%')"),
        CompletionItem(label: "isNull",      kind: "function", detail: "IS NULL",         insertText: "isNull()"),
        CompletionItem(label: "isNotNull",   kind: "function", detail: "IS NOT NULL",     insertText: "isNotNull()"),
        CompletionItem(label: "inArray",     kind: "function", detail: "IN (…)",          insertText: "inArray(, [])"),
        CompletionItem(label: "notInArray",  kind: "function", detail: "NOT IN (…)",      insertText: "notInArray(, [])"),
        CompletionItem(label: "between",     kind: "function", detail: "BETWEEN a AND b", insertText: "between(, , )"),
        CompletionItem(label: "notBetween",  kind: "function", detail: "NOT BETWEEN",     insertText: "notBetween(, , )"),
        CompletionItem(label: "exists",      kind: "function", detail: "EXISTS",          insertText: "exists()"),
        CompletionItem(label: "notExists",   kind: "function", detail: "NOT EXISTS",      insertText: "notExists()"),
        CompletionItem(label: "sql",         kind: "snippet",  detail: "Raw SQL template",insertText: "sql``"),
    ]

    private let columnTypeItems: [CompletionItem] = [
        CompletionItem(label: "text",             kind: "function", detail: "TEXT",              insertText: "text('')"),
        CompletionItem(label: "varchar",          kind: "function", detail: "VARCHAR(n)",         insertText: "varchar('', { length: 255 })"),
        CompletionItem(label: "char",             kind: "function", detail: "CHAR(n)",            insertText: "char('', { length: 1 })"),
        CompletionItem(label: "integer",          kind: "function", detail: "INTEGER",            insertText: "integer('')"),
        CompletionItem(label: "bigint",           kind: "function", detail: "BIGINT",             insertText: "bigint('', { mode: 'number' })"),
        CompletionItem(label: "smallint",         kind: "function", detail: "SMALLINT",           insertText: "smallint('')"),
        CompletionItem(label: "serial",           kind: "function", detail: "SERIAL (auto-inc)",  insertText: "serial('')"),
        CompletionItem(label: "bigserial",        kind: "function", detail: "BIGSERIAL",          insertText: "bigserial('')"),
        CompletionItem(label: "boolean",          kind: "function", detail: "BOOLEAN",            insertText: "boolean('')"),
        CompletionItem(label: "timestamp",        kind: "function", detail: "TIMESTAMP WITH TZ",  insertText: "timestamp('', { withTimezone: true })"),
        CompletionItem(label: "date",             kind: "function", detail: "DATE",               insertText: "date('')"),
        CompletionItem(label: "time",             kind: "function", detail: "TIME",               insertText: "time('')"),
        CompletionItem(label: "uuid",             kind: "function", detail: "UUID",               insertText: "uuid('').defaultRandom()"),
        CompletionItem(label: "json",             kind: "function", detail: "JSON",               insertText: "json('')"),
        CompletionItem(label: "jsonb",            kind: "function", detail: "JSONB",              insertText: "jsonb('')"),
        CompletionItem(label: "decimal",          kind: "function", detail: "DECIMAL(p,s)",       insertText: "decimal('', { precision: 10, scale: 2 })"),
        CompletionItem(label: "doublePrecision",  kind: "function", detail: "DOUBLE PRECISION",   insertText: "doublePrecision('')"),
        CompletionItem(label: "real",             kind: "function", detail: "REAL",               insertText: "real('')"),
        CompletionItem(label: "pgEnum",           kind: "function", detail: "Postgres ENUM type", insertText: "pgEnum('', ['', ''])"),
        CompletionItem(label: "primaryKey",       kind: "function", detail: "Composite PK",       insertText: "primaryKey({ columns: [] })"),
        CompletionItem(label: "index",            kind: "function", detail: "Index on columns",   insertText: "index('_idx').on()"),
        CompletionItem(label: "uniqueIndex",      kind: "function", detail: "Unique index",       insertText: "uniqueIndex('_idx').on()"),
        CompletionItem(label: "foreignKey",       kind: "function", detail: "Foreign key",        insertText: "foreignKey({ columns: [], foreignColumns: [] })"),
        CompletionItem(label: "pgTable",          kind: "function", detail: "Define a Postgres table", insertText: "pgTable('', {\n\t\n})"),
        CompletionItem(label: "mysqlTable",       kind: "function", detail: "Define a MySQL table",    insertText: "mysqlTable('', {\n\t\n})"),
        CompletionItem(label: "sqliteTable",      kind: "function", detail: "Define a SQLite table",   insertText: "sqliteTable('', {\n\t\n})"),
        CompletionItem(label: "notNull",          kind: "method",   detail: ".notNull()",         insertText: "notNull()"),
        CompletionItem(label: "default",          kind: "method",   detail: ".default(value)",    insertText: "default()"),
        CompletionItem(label: "defaultNow",       kind: "method",   detail: ".defaultNow()",      insertText: "defaultNow()"),
        CompletionItem(label: "defaultRandom",    kind: "method",   detail: ".defaultRandom()",   insertText: "defaultRandom()"),
        CompletionItem(label: "references",       kind: "method",   detail: ".references(() => table.col)", insertText: "references(() => )"),
        CompletionItem(label: "onDelete",         kind: "method",   detail: ".onDelete('cascade')", insertText: "onDelete('cascade')"),
        CompletionItem(label: "onUpdate",         kind: "method",   detail: ".onUpdate('cascade')", insertText: "onUpdate('cascade')"),
    ]

    private let sqlFunctionItems: [CompletionItem] = [
        CompletionItem(label: "count",          kind: "function", detail: "COUNT(*)",    insertText: "count()"),
        CompletionItem(label: "countDistinct",  kind: "function", detail: "COUNT(DISTINCT …)", insertText: "countDistinct()"),
        CompletionItem(label: "sum",            kind: "function", detail: "SUM",         insertText: "sum()"),
        CompletionItem(label: "avg",            kind: "function", detail: "AVG",         insertText: "avg()"),
        CompletionItem(label: "max",            kind: "function", detail: "MAX",         insertText: "max()"),
        CompletionItem(label: "min",            kind: "function", detail: "MIN",         insertText: "min()"),
        CompletionItem(label: "coalesce",       kind: "function", detail: "COALESCE",    insertText: "coalesce(, )"),
        CompletionItem(label: "lower",          kind: "function", detail: "LOWER",       insertText: "lower()"),
        CompletionItem(label: "upper",          kind: "function", detail: "UPPER",       insertText: "upper()"),
        CompletionItem(label: "length",         kind: "function", detail: "LENGTH",      insertText: "length()"),
        CompletionItem(label: "asc",            kind: "function", detail: "ASC order",   insertText: "asc()"),
        CompletionItem(label: "desc",           kind: "function", detail: "DESC order",  insertText: "desc()"),
    ]

    private let relationItems: [CompletionItem] = [
        CompletionItem(label: "relations", kind: "function", detail: "Define table relations",
                       insertText: "relations(, ({ one, many }) => ({\n\t\n}))"),
        CompletionItem(label: "one",       kind: "function", detail: "One-to-one / many-to-one",
                       insertText: "one(, { fields: [], references: [] })"),
        CompletionItem(label: "many",      kind: "function", detail: "One-to-many",
                       insertText: "many()"),
    ]
}
