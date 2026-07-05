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

    // Insert-texts below use VS Code-style snippet syntax (`$1`/`${1:placeholder}`/`$0`)
    // wherever the completion has an actual fill-in-the-blank shape — expanded and
    // Tab-cycled by `SnippetEngine` (see `Editor/SnippetEngine.swift`) from
    // `EditorView.Coordinator.insertCompletion`. Completions with no meaningful
    // argument (`notNull()`, `defaultNow()`, …) are left as plain literal text.
    private let queryBuilderItems: [CompletionItem] = [
        CompletionItem(label: "select",        kind: "method",   detail: "SELECT columns",        insertText: "select()"),
        CompletionItem(label: "selectDistinct",kind: "method",   detail: "SELECT DISTINCT",       insertText: "selectDistinct()"),
        CompletionItem(label: "from",          kind: "method",   detail: "FROM table",            insertText: "from(${1:table})"),
        CompletionItem(label: "where",         kind: "method",   detail: "WHERE condition",       insertText: "where(${1:condition})"),
        CompletionItem(label: "orderBy",       kind: "method",   detail: "ORDER BY",              insertText: "orderBy(${1:column})"),
        CompletionItem(label: "limit",         kind: "method",   detail: "LIMIT n",               insertText: "limit(${1:n})"),
        CompletionItem(label: "offset",        kind: "method",   detail: "OFFSET n",              insertText: "offset(${1:n})"),
        CompletionItem(label: "groupBy",       kind: "method",   detail: "GROUP BY",              insertText: "groupBy(${1:column})"),
        CompletionItem(label: "having",        kind: "method",   detail: "HAVING condition",      insertText: "having(${1:condition})"),
        CompletionItem(label: "innerJoin",     kind: "method",   detail: "INNER JOIN",            insertText: "innerJoin(${1:table}, eq(${2:table.column}, ${3:otherTable.column}))"),
        CompletionItem(label: "leftJoin",      kind: "method",   detail: "LEFT JOIN",             insertText: "leftJoin(${1:table}, eq(${2:table.column}, ${3:otherTable.column}))"),
        CompletionItem(label: "rightJoin",     kind: "method",   detail: "RIGHT JOIN",            insertText: "rightJoin(${1:table}, eq(${2:table.column}, ${3:otherTable.column}))"),
        CompletionItem(label: "fullJoin",      kind: "method",   detail: "FULL JOIN",             insertText: "fullJoin(${1:table}, eq(${2:table.column}, ${3:otherTable.column}))"),
        CompletionItem(label: "insert",        kind: "method",   detail: "INSERT INTO",           insertText: "insert(${1:table})"),
        CompletionItem(label: "values",        kind: "method",   detail: ".values({ … })",        insertText: "values({ ${1:column}: ${2:value} })"),
        CompletionItem(label: "update",        kind: "method",   detail: "UPDATE table",          insertText: "update(${1:table})"),
        CompletionItem(label: "set",           kind: "method",   detail: ".set({ col: val })",    insertText: "set({ ${1:column}: ${2:value} })"),
        CompletionItem(label: "delete",        kind: "method",   detail: "DELETE FROM",           insertText: "delete(${1:table})"),
        CompletionItem(label: "onConflictDoNothing", kind: "method", detail: "ON CONFLICT DO NOTHING", insertText: "onConflictDoNothing()"),
        CompletionItem(label: "onConflictDoUpdate",  kind: "method", detail: "ON CONFLICT DO UPDATE",  insertText: "onConflictDoUpdate({ target: ${1:column}, set: { ${2:column}: ${3:value} } })"),
        CompletionItem(label: "query",         kind: "method",   detail: "Relational query API",  insertText: "query"),
        CompletionItem(label: "transaction",   kind: "method",   detail: "Begin transaction",     insertText: "transaction(async (tx) => {\n\t$1\n})"),
        CompletionItem(label: "execute",       kind: "method",   detail: "Execute raw SQL",       insertText: "execute(sql`${1:SELECT 1}`)"),
        CompletionItem(label: "with",          kind: "method",   detail: "WITH (relational with)", insertText: "with({ ${1:name}: ${2:query} })"),
        CompletionItem(label: "returning",     kind: "method",   detail: "RETURNING columns",     insertText: "returning()"),
    ]

    private let operatorItems: [CompletionItem] = [
        CompletionItem(label: "eq",          kind: "function", detail: "=",               insertText: "eq(${1:column}, ${2:value})"),
        CompletionItem(label: "ne",          kind: "function", detail: "!=",              insertText: "ne(${1:column}, ${2:value})"),
        CompletionItem(label: "lt",          kind: "function", detail: "<",               insertText: "lt(${1:column}, ${2:value})"),
        CompletionItem(label: "lte",         kind: "function", detail: "<=",              insertText: "lte(${1:column}, ${2:value})"),
        CompletionItem(label: "gt",          kind: "function", detail: ">",               insertText: "gt(${1:column}, ${2:value})"),
        CompletionItem(label: "gte",         kind: "function", detail: ">=",              insertText: "gte(${1:column}, ${2:value})"),
        CompletionItem(label: "and",         kind: "function", detail: "AND",             insertText: "and(${1:condition1}, ${2:condition2})"),
        CompletionItem(label: "or",          kind: "function", detail: "OR",              insertText: "or(${1:condition1}, ${2:condition2})"),
        CompletionItem(label: "not",         kind: "function", detail: "NOT",             insertText: "not(${1:condition})"),
        CompletionItem(label: "like",        kind: "function", detail: "LIKE '%…%'",      insertText: "like(${1:column}, '${2:%pattern%}')"),
        CompletionItem(label: "ilike",       kind: "function", detail: "ILIKE '%…%'",     insertText: "ilike(${1:column}, '${2:%pattern%}')"),
        CompletionItem(label: "notLike",     kind: "function", detail: "NOT LIKE",        insertText: "notLike(${1:column}, '${2:%pattern%}')"),
        CompletionItem(label: "isNull",      kind: "function", detail: "IS NULL",         insertText: "isNull(${1:column})"),
        CompletionItem(label: "isNotNull",   kind: "function", detail: "IS NOT NULL",     insertText: "isNotNull(${1:column})"),
        CompletionItem(label: "inArray",     kind: "function", detail: "IN (…)",          insertText: "inArray(${1:column}, [${2:values}])"),
        CompletionItem(label: "notInArray",  kind: "function", detail: "NOT IN (…)",      insertText: "notInArray(${1:column}, [${2:values}])"),
        CompletionItem(label: "between",     kind: "function", detail: "BETWEEN a AND b", insertText: "between(${1:column}, ${2:min}, ${3:max})"),
        CompletionItem(label: "notBetween",  kind: "function", detail: "NOT BETWEEN",     insertText: "notBetween(${1:column}, ${2:min}, ${3:max})"),
        CompletionItem(label: "exists",      kind: "function", detail: "EXISTS",          insertText: "exists(${1:subquery})"),
        CompletionItem(label: "notExists",   kind: "function", detail: "NOT EXISTS",      insertText: "notExists(${1:subquery})"),
        CompletionItem(label: "sql",         kind: "snippet",  detail: "Raw SQL template",insertText: "sql`${1:SELECT 1}`"),
    ]

    private let columnTypeItems: [CompletionItem] = [
        CompletionItem(label: "text",             kind: "function", detail: "TEXT",              insertText: "text('${1:name}')"),
        CompletionItem(label: "varchar",          kind: "function", detail: "VARCHAR(n)",         insertText: "varchar('${1:name}', { length: ${2:255} })"),
        CompletionItem(label: "char",             kind: "function", detail: "CHAR(n)",            insertText: "char('${1:name}', { length: ${2:1} })"),
        CompletionItem(label: "integer",          kind: "function", detail: "INTEGER",            insertText: "integer('${1:name}')"),
        CompletionItem(label: "bigint",           kind: "function", detail: "BIGINT",             insertText: "bigint('${1:name}', { mode: '${2:number}' })"),
        CompletionItem(label: "smallint",         kind: "function", detail: "SMALLINT",           insertText: "smallint('${1:name}')"),
        CompletionItem(label: "serial",           kind: "function", detail: "SERIAL (auto-inc)",  insertText: "serial('${1:name}')"),
        CompletionItem(label: "bigserial",        kind: "function", detail: "BIGSERIAL",          insertText: "bigserial('${1:name}')"),
        CompletionItem(label: "boolean",          kind: "function", detail: "BOOLEAN",            insertText: "boolean('${1:name}')"),
        CompletionItem(label: "timestamp",        kind: "function", detail: "TIMESTAMP WITH TZ",  insertText: "timestamp('${1:name}', { withTimezone: true })"),
        CompletionItem(label: "date",             kind: "function", detail: "DATE",               insertText: "date('${1:name}')"),
        CompletionItem(label: "time",             kind: "function", detail: "TIME",               insertText: "time('${1:name}')"),
        CompletionItem(label: "uuid",             kind: "function", detail: "UUID",               insertText: "uuid('${1:name}').defaultRandom()"),
        CompletionItem(label: "json",             kind: "function", detail: "JSON",               insertText: "json('${1:name}')"),
        CompletionItem(label: "jsonb",            kind: "function", detail: "JSONB",              insertText: "jsonb('${1:name}')"),
        CompletionItem(label: "decimal",          kind: "function", detail: "DECIMAL(p,s)",       insertText: "decimal('${1:name}', { precision: ${2:10}, scale: ${3:2} })"),
        CompletionItem(label: "doublePrecision",  kind: "function", detail: "DOUBLE PRECISION",   insertText: "doublePrecision('${1:name}')"),
        CompletionItem(label: "real",             kind: "function", detail: "REAL",               insertText: "real('${1:name}')"),
        CompletionItem(label: "pgEnum",           kind: "function", detail: "Postgres ENUM type", insertText: "pgEnum('${1:name}', ['${2:value1}', '${3:value2}'])"),
        CompletionItem(label: "primaryKey",       kind: "function", detail: "Composite PK",       insertText: "primaryKey({ columns: [${1:columns}] })"),
        CompletionItem(label: "index",            kind: "function", detail: "Index on columns",   insertText: "index('${1:name}_idx').on(${2:column})"),
        CompletionItem(label: "uniqueIndex",      kind: "function", detail: "Unique index",       insertText: "uniqueIndex('${1:name}_idx').on(${2:column})"),
        CompletionItem(label: "foreignKey",       kind: "function", detail: "Foreign key",        insertText: "foreignKey({ columns: [${1:column}], foreignColumns: [${2:refColumn}] })"),
        CompletionItem(label: "pgTable",          kind: "function", detail: "Define a Postgres table", insertText: "pgTable('${1:name}', {\n\t$2\n})"),
        CompletionItem(label: "mysqlTable",       kind: "function", detail: "Define a MySQL table",    insertText: "mysqlTable('${1:name}', {\n\t$2\n})"),
        CompletionItem(label: "sqliteTable",      kind: "function", detail: "Define a SQLite table",   insertText: "sqliteTable('${1:name}', {\n\t$2\n})"),
        CompletionItem(label: "notNull",          kind: "method",   detail: ".notNull()",         insertText: "notNull()"),
        CompletionItem(label: "default",          kind: "method",   detail: ".default(value)",    insertText: "default(${1:value})"),
        CompletionItem(label: "defaultNow",       kind: "method",   detail: ".defaultNow()",      insertText: "defaultNow()"),
        CompletionItem(label: "defaultRandom",    kind: "method",   detail: ".defaultRandom()",   insertText: "defaultRandom()"),
        CompletionItem(label: "references",       kind: "method",   detail: ".references(() => table.col)", insertText: "references(() => ${1:table.column})"),
        CompletionItem(label: "onDelete",         kind: "method",   detail: ".onDelete('cascade')", insertText: "onDelete('${1:cascade}')"),
        CompletionItem(label: "onUpdate",         kind: "method",   detail: ".onUpdate('cascade')", insertText: "onUpdate('${1:cascade}')"),
    ]

    private let sqlFunctionItems: [CompletionItem] = [
        CompletionItem(label: "count",          kind: "function", detail: "COUNT(*)",    insertText: "count()"),
        CompletionItem(label: "countDistinct",  kind: "function", detail: "COUNT(DISTINCT …)", insertText: "countDistinct(${1:column})"),
        CompletionItem(label: "sum",            kind: "function", detail: "SUM",         insertText: "sum(${1:column})"),
        CompletionItem(label: "avg",            kind: "function", detail: "AVG",         insertText: "avg(${1:column})"),
        CompletionItem(label: "max",            kind: "function", detail: "MAX",         insertText: "max(${1:column})"),
        CompletionItem(label: "min",            kind: "function", detail: "MIN",         insertText: "min(${1:column})"),
        CompletionItem(label: "coalesce",       kind: "function", detail: "COALESCE",    insertText: "coalesce(${1:column}, ${2:default})"),
        CompletionItem(label: "lower",          kind: "function", detail: "LOWER",       insertText: "lower(${1:column})"),
        CompletionItem(label: "upper",          kind: "function", detail: "UPPER",       insertText: "upper(${1:column})"),
        CompletionItem(label: "length",         kind: "function", detail: "LENGTH",      insertText: "length(${1:column})"),
        CompletionItem(label: "asc",            kind: "function", detail: "ASC order",   insertText: "asc(${1:column})"),
        CompletionItem(label: "desc",           kind: "function", detail: "DESC order",  insertText: "desc(${1:column})"),
    ]

    private let relationItems: [CompletionItem] = [
        CompletionItem(label: "relations", kind: "function", detail: "Define table relations",
                       insertText: "relations(${1:table}, ({ one, many }) => ({\n\t$2\n}))"),
        CompletionItem(label: "one",       kind: "function", detail: "One-to-one / many-to-one",
                       insertText: "one(${1:table}, { fields: [${2:column}], references: [${3:refColumn}] })"),
        CompletionItem(label: "many",      kind: "function", detail: "One-to-many",
                       insertText: "many(${1:table})"),
    ]
}
