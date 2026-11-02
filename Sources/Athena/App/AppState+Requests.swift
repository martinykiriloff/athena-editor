// AppState+Requests.swift
// Athena — .http request sending and the SQL query editor (run, results panel, history, schema completion).
// Swift 6, strict concurrency.

import AppKit
import Foundation

// MARK: - RequestCenter

/// State for the HTTP client and SQL editor. A separate object (held by
/// `AppState` as `requestCenter`) because an extension can't add stored properties.
@Observable @MainActor
final class RequestCenter {
    // HTTP
    var httpResponse: HTTPResponseResult?
    var httpError: String?
    var httpIsSending = false
    @ObservationIgnored let http = HTTPClientService()

    // SQL
    var sqlHistory: [SQLHistoryEntry] = []
    var sqlError: String?
    @ObservationIgnored let sqlCompletion = SQLCompletionService()
    @ObservationIgnored var sqlSchemaConnectionId: UUID?
}

// MARK: - AppState

@MainActor
extension AppState {

    // MARK: Dispatch (⌘⏎)

    private var focusedFileURL: URL? { focusedTab?.fileURL }

    /// True when ⌘⏎ should run something: the editor is first responder on
    /// a `.http` / `.rest` / `.sql` file. Anywhere else the key passes through.
    var canRunRequestOrQuery: Bool {
        guard NSApp.keyWindow?.firstResponder is AthenaTextView, let url = focusedFileURL else { return false }
        return HTTPRequestParser.isHTTPFile(url) || url.pathExtension.lowercased() == "sql"
    }

    func runRequestOrQuery() async {
        guard let tab = focusedTab, let url = tab.fileURL else { return }
        if HTTPRequestParser.isHTTPFile(url) {
            await sendHTTPRequest(inText: tab.content, atLine: tab.cursorLine)
        } else if url.pathExtension.lowercased() == "sql" {
            await runSQLInEditor(tab)
        }
    }

    // MARK: HTTP

    func sendHTTPRequest(inText text: String, atLine line: Int) async {
        let requests = HTTPRequestParser.parse(text)
        guard let spec = HTTPRequestParser.request(atLine: line, in: requests) else {
            statusMessage = "No HTTP request found at the cursor."
            return
        }
        requestCenter.httpIsSending = true
        requestCenter.httpError = nil
        showBottomPanel = true
        activeBottomPanel = .httpResponse
        defer { requestCenter.httpIsSending = false }
        do {
            requestCenter.httpResponse = try await requestCenter.http.send(spec)
        } catch {
            requestCenter.httpResponse = nil
            requestCenter.httpError = error.localizedDescription
        }
    }

    /// "Send Request" links for a `.http` file, keyed by the request line.
    func httpAnnotations(for tab: TabModel) -> [Int: VirtualAnnotation] {
        guard HTTPRequestParser.isHTTPFile(tab.fileURL) else { return [:] }
        var out: [Int: VirtualAnnotation] = [:]
        for r in HTTPRequestParser.parse(tab.content) {
            out[r.startLine] = VirtualAnnotation(text: "▶ Send Request" + (r.name.map { " · \($0)" } ?? ""), isAction: true)
        }
        return out
    }

    func copyHTTPResponseBody() {
        guard let body = requestCenter.httpResponse?.prettyBody else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    // MARK: SQL

    /// Runs the statement at the caret of a `.sql` tab against the connection
    /// open in the Database panel.
    func runSQLInEditor(_ tab: TabModel) async {
        guard let connectionId = dbBrowserConnectionId,
              let connection = dbConnections.first(where: { $0.id == connectionId }),
              let engine = dbEngine(for: connection.type) else {
            statusMessage = "Connect to a database in the Database panel first."
            requestCenter.sqlError = "No active database connection."
            showBottomPanel = true
            activeBottomPanel = .queryResults
            return
        }
        let offset = Self.utf16Offset(in: tab.content, line: tab.cursorLine, column: tab.cursorColumn)
        guard let sql = SQLStatementSplitter.statement(in: tab.content, atOffset: offset) else { return }
        await runSQL(sql, connection: connection, engine: engine)
    }

    func rerunSQL(_ entry: SQLHistoryEntry) async {
        guard let connectionId = dbBrowserConnectionId,
              let connection = dbConnections.first(where: { $0.id == connectionId }),
              let engine = dbEngine(for: connection.type) else { return }
        await runSQL(entry.sql, connection: connection, engine: engine)
    }

    private func runSQL(_ sql: String, connection: DBConnection, engine: any DBEngine) async {
        showBottomPanel = true
        activeBottomPanel = .queryResults
        dbQueryIsRunning = true
        requestCenter.sqlError = nil
        defer { dbQueryIsRunning = false }
        requestCenter.sqlHistory = SQLHistory.adding(
            SQLHistoryEntry(sql: sql, connectionName: connection.name, date: Date()), to: requestCenter.sqlHistory)
        do {
            dbQueryResult = try await engine.runQuery(connection.id, sql: sql, limit: 500)
        } catch {
            dbQueryResult = nil
            requestCenter.sqlError = error.localizedDescription
        }
    }

    /// Completions for a `.sql` tab, loading the connection's schema on first use.
    func sqlCompletions(text: String, line: Int, col: Int) async -> [CompletionItem] {
        await loadSQLSchemaIfNeeded()
        return await requestCenter.sqlCompletion.complete(text: text, line: line, col: col)
    }

    private func loadSQLSchemaIfNeeded() async {
        guard let id = dbBrowserConnectionId, requestCenter.sqlSchemaConnectionId != id,
              let connection = dbConnections.first(where: { $0.id == id }),
              let engine = dbEngine(for: connection.type) else { return }
        var schema = SQLSchema(tables: dbBrowserTables)
        for table in dbBrowserTables.prefix(300) {
            if let cols = try? await engine.columns(id, table: table) { schema.columns[table.name.lowercased()] = cols }
        }
        await requestCenter.sqlCompletion.setSchema(schema)
        requestCenter.sqlSchemaConnectionId = id
    }

    nonisolated static func utf16Offset(in text: String, line: Int, column: Int) -> Int {
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        for i in 0..<max(0, min(line - 1, lines.count)) { offset += (lines[i] as NSString).length + 1 }
        if line - 1 < lines.count { offset += min(max(0, column - 1), (lines[line - 1] as NSString).length) }
        return offset
    }
}
