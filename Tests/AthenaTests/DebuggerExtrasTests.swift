// DebuggerExtrasTests.swift
// Athena — breakpoint option request builders, logpoints, hit counts, persistence, inline values,
// the .http parser, JSON pretty-printing and SQL completion / statement splitting.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

@Suite("Breakpoint request builders")
struct BreakpointRequestBuilderTests {

    @Test func hitConditionParsing() {
        #expect(HitCondition.parse("5") == HitCondition(op: .eq, value: 5))
        #expect(HitCondition.parse(">= 3") == HitCondition(op: .ge, value: 3))
        #expect(HitCondition.parse("%2") == HitCondition(op: .mod, value: 2))
        #expect(HitCondition.parse("%0") == nil)
        #expect(HitCondition.parse("abc") == nil)
        #expect(HitCondition.parse("  ") == nil)
        #expect(HitCondition.parse(">3")!.matches(hitCount: 4))
        #expect(!HitCondition.parse(">3")!.matches(hitCount: 3))
        #expect(HitCondition.parse("%3")!.matches(hitCount: 6))
    }

    @Test func logTemplateParsing() {
        #expect(LogMessageTemplate.parse("a {x} b") == [.text("a "), .expression("x"), .text(" b")])
        #expect(LogMessageTemplate.parse("{}") == [.text("{}")])
        #expect(LogMessageTemplate.parse("\\{x\\}") == [.text("{x}")])
        #expect(LogMessageTemplate.parse("open {") == [.text("open {")])
        #expect(LogMessageTemplate.parse("{a.b({c})}") == [.expression("a.b({c})")])
        #expect(LogMessageTemplate.render("n={n}, s={s}") { $0 == "n" ? "1" : "x" } == "n=1, s=x")
    }

    @Test func javaScriptTemplateEscapes() {
        let js = LogMessageTemplate.javaScriptTemplate("cost `$5` {price}")
        #expect(js.hasPrefix("`cost \\`\\$5\\` "))
        #expect(js.contains("${(()=>{try{return (price)}"))
    }

    @Test func dapSourceBreakpoints() {
        let opts: [Int: BreakpointOptions] = [
            3: BreakpointOptions(condition: "x > 1"),
            5: BreakpointOptions(hitCondition: ">=2", logMessage: "v={v}"),
        ]
        let bps = BreakpointRequestBuilder.dapSourceBreakpoints(lines: [5, 3, 9], options: opts)
        #expect(bps.count == 3)
        #expect(bps[0]["line"] as? Int == 3)
        #expect(bps[0]["condition"] as? String == "x > 1")
        #expect(bps[0]["hitCondition"] == nil)
        #expect(bps[1]["hitCondition"] as? String == ">=2")
        #expect(bps[1]["logMessage"] as? String == "v={v}")
        #expect(bps[2].keys.sorted() == ["line"])
    }

    @Test func disabledLinesAreNotSent() {
        let opts: [Int: BreakpointOptions] = [2: BreakpointOptions(isEnabled: false)]
        #expect(BreakpointRequestBuilder.activeLines([3, 2, 1], options: opts) == [1, 3])
    }

    @Test func dapExceptionFilters() {
        let all = ExceptionBreakpointSettings(breakOnAll: true, breakOnUncaught: false)
        let unc = ExceptionBreakpointSettings(breakOnAll: false, breakOnUncaught: true)
        #expect(BreakpointRequestBuilder.dapExceptionFilters(all, available: ["uncaught", "all"]) == ["all"])
        #expect(BreakpointRequestBuilder.dapExceptionFilters(unc, available: ["uncaught", "all"]) == ["uncaught"])
        #expect(BreakpointRequestBuilder.dapExceptionFilters(all, available: ["cpp_throw", "cpp_catch"]) == ["cpp_throw"])
        #expect(BreakpointRequestBuilder.dapExceptionFilters(all, available: []) == ["all"])
        #expect(BreakpointRequestBuilder.dapExceptionFilters(ExceptionBreakpointSettings(), available: ["all"]) == [])
    }

    @Test func cdpPauseState() {
        #expect(BreakpointRequestBuilder.cdpPauseOnExceptionsState(ExceptionBreakpointSettings()) == "none")
        #expect(BreakpointRequestBuilder.cdpPauseOnExceptionsState(ExceptionBreakpointSettings(breakOnAll: false, breakOnUncaught: true)) == "uncaught")
        #expect(BreakpointRequestBuilder.cdpPauseOnExceptionsState(ExceptionBreakpointSettings(breakOnAll: true, breakOnUncaught: true)) == "all")
    }

    @Test func cdpConditionShapes() {
        #expect(BreakpointRequestBuilder.cdpCondition(options: nil, key: "k") == nil)
        #expect(BreakpointRequestBuilder.cdpCondition(options: BreakpointOptions(), key: "k") == nil)
        #expect(BreakpointRequestBuilder.cdpCondition(options: BreakpointOptions(condition: " i > 2 "), key: "k") == "i > 2")
        let hit = BreakpointRequestBuilder.cdpCondition(options: BreakpointOptions(hitCondition: "3"), key: "a.js:4")!
        #expect(hit.contains("__athenaHits") && hit.contains("_n===3") && hit.contains("\"a.js:4\""))
        let log = BreakpointRequestBuilder.cdpCondition(options: BreakpointOptions(logMessage: "hi {x}"), key: "k")!
        #expect(log.contains("console.log(`hi ${") && log.contains("return false;})()"))
    }

    @Test func truthiness() {
        for f in ["false", "0", "", "undefined", "null", " False "] { #expect(!BreakpointRequestBuilder.isTruthy(f)) }
        for t in ["true", "1", "\"a\"", "[object Object]"] { #expect(BreakpointRequestBuilder.isTruthy(t)) }
    }

    @Test func optionsGlyphStyleAndPlainness() {
        #expect(BreakpointOptions().isPlain)
        #expect(BreakpointOptions(condition: "x").glyphStyle == .conditional)
        #expect(BreakpointOptions(hitCondition: "2").glyphStyle == .conditional)
        #expect(BreakpointOptions(logMessage: "m").glyphStyle == .logpoint)
        #expect(BreakpointOptions(isEnabled: false).glyphStyle == .disabled)
    }

    @Test func persistenceRoundTrip() throws {
        let lines: [String: Set<Int>] = ["/p/a.ts": [1, 4], "/p/b.ts": [2]]
        let options: [String: [Int: BreakpointOptions]] = ["/p/a.ts": [4: BreakpointOptions(condition: "x")]]
        let ex = ExceptionBreakpointSettings(breakOnAll: false, breakOnUncaught: true)
        let config = BreakpointRequestBuilder.persisted(lines: lines, options: options, exceptions: ex)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("athena-bp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = URL(fileURLWithPath: "/Users/dev/shop")
        BreakpointStore.save(config, workspace: root, directory: dir)
        let loaded = try #require(BreakpointStore.load(workspace: root, directory: dir))
        #expect(loaded == config)
        let restored = BreakpointRequestBuilder.restore(loaded)
        #expect(restored.lines == lines)
        #expect(restored.options == options)
        #expect(loaded.exceptions == ex)
        #expect(BreakpointStore.load(workspace: URL(fileURLWithPath: "/other"), directory: dir) == nil)
    }

    @Test func inlineValuesPickMatchingLocals() {
        func v(_ n: String, _ val: String) -> DebugVariable { DebugVariable(name: n, value: val, type: nil, variablesReference: 0) }
        let vars = [v("count", "3"), v("name", "\"ada\""), v("unused", "1")]
        #expect(InlineValueFormatter.annotation(forLine: "total = count + count * 2", variables: vars) == "count = 3")
        #expect(InlineValueFormatter.annotation(forLine: "greet(name, count)", variables: vars) == "name = \"ada\", count = 3")
        #expect(InlineValueFormatter.annotation(forLine: "user.name = 1", variables: vars) == nil)
        #expect(InlineValueFormatter.annotation(forLine: "nothing here", variables: vars) == nil)
        #expect(InlineValueFormatter.annotation(forLine: "x", variables: []) == nil)
        let long = [v("big", String(repeating: "a", count: 100))]
        #expect(InlineValueFormatter.annotation(forLine: "big", variables: long)!.hasSuffix("…"))
    }
}

@Suite("HTTP client parsing")
struct HTTPRequestParserTests {

    private let sample = """
    @host = https://api.example.com
    @token = abc123
    @base = {{host}}/v1

    ### list users
    # a comment
    GET {{base}}/users?limit=5
        &page=2 HTTP/1.1
    Authorization: Bearer {{token}}
    Accept: application/json

    ### create
    POST {{base}}/users
    Content-Type: application/json

    {
      "name": "Ada"
    }

    ###
    // @name ping
    https://example.com/ping
    """

    @Test func parsesRequests() {
        let reqs = HTTPRequestParser.parse(sample)
        #expect(reqs.count == 3)
        #expect(reqs[0].name == "list users")
        #expect(reqs[0].method == "GET")
        #expect(reqs[0].url == "https://api.example.com/v1/users?limit=5&page=2")
        #expect(reqs[0].headers == [HTTPHeader(name: "Authorization", value: "Bearer abc123"),
                                    HTTPHeader(name: "Accept", value: "application/json")])
        #expect(reqs[0].body == nil)
        #expect(reqs[1].method == "POST")
        #expect(reqs[1].body == "{\n  \"name\": \"Ada\"\n}")
        #expect(reqs[2].name == "ping")
        #expect(reqs[2].method == "GET")
        #expect(reqs[2].url == "https://example.com/ping")
    }

    @Test func startLinesAndLookup() {
        let reqs = HTTPRequestParser.parse(sample)
        #expect(reqs[0].startLine == 7)
        #expect(HTTPRequestParser.request(atLine: 7, in: reqs)?.name == "list users")
        #expect(HTTPRequestParser.request(atLine: 13, in: reqs)?.name == "create")   // the ### line picks the next request
        #expect(HTTPRequestParser.request(atLine: 999, in: reqs)?.name == "ping")
    }

    @Test func dynamicVariables() {
        let text = "GET https://x.test/{{$timestamp}}/{{$processEnv HOME_X}}/{{missing}}\n"
        let r = HTTPRequestParser.parse(text, environment: ["HOME_X": "h"], now: Date(timeIntervalSince1970: 1000))
        #expect(r[0].url == "https://x.test/1000/h/{{missing}}")
        let g = HTTPRequestParser.substitute("{{$guid}}", variables: [:], environment: [:], now: Date())
        #expect(UUID(uuidString: g) != nil)
    }

    @Test func fileTypeDetection() {
        #expect(HTTPRequestParser.isHTTPFile(URL(fileURLWithPath: "/a/b.http")))
        #expect(HTTPRequestParser.isHTTPFile(URL(fileURLWithPath: "/a/b.REST")))
        #expect(!HTTPRequestParser.isHTTPFile(URL(fileURLWithPath: "/a/b.txt")))
        #expect(!HTTPRequestParser.isHTTPFile(nil))
    }

    @Test func prettyPrintsJSONKeepingKeyOrder() {
        let out = JSONPrettyPrinter.format("{\"z\":1,\"a\":[1,2,{\"k\":\"v,}\"}],\"e\":{},\"f\":[]}")
        #expect(out == "{\n  \"z\": 1,\n  \"a\": [\n    1,\n    2,\n    {\n      \"k\": \"v,}\"\n    }\n  ],\n  \"e\": {},\n  \"f\": []\n}")
        #expect(JSONPrettyPrinter.format("not json") == nil)
    }

    @Test func requestAndResponseHelpers() throws {
        let spec = HTTPRequestSpec(name: nil, method: "POST", url: "https://x.test/a", headers: [HTTPHeader(name: "X-A", value: "1")],
                                   body: "hi", startLine: 1, endLine: 3)
        let req = try HTTPClientService.makeRequest(spec)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "X-A") == "1")
        #expect(req.httpBody == Data("hi".utf8))
        var bad = spec; bad.url = "nope"
        #expect(throws: HTTPClientError.self) { try HTTPClientService.makeRequest(bad) }

        let http = HTTPURLResponse(url: URL(string: "https://x.test/a")!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        let result = HTTPClientService.summarise(spec: spec, response: http, data: Data("{\"a\":1}".utf8), elapsed: .milliseconds(12))
        #expect(result.statusCode == 200 && result.isJSON && result.byteCount == 7)
        #expect(result.prettyBody == "{\n  \"a\": 1\n}")
        #expect(abs(result.durationMs - 12) < 0.5)
        #expect(HTTPClientService.formatSize(2048) == "2.0 KB")
    }
}

@Suite("SQL editor logic")
struct SQLEditorLogicTests {

    private var schema: SQLSchema {
        SQLSchema(
            tables: [DBTableRef(schema: "public", name: "users"), DBTableRef(schema: "public", name: "orders")],
            columns: [
                "users": [DBColumn(name: "id", dataTypeName: "int", isPrimaryKey: true), DBColumn(name: "email", dataTypeName: "text", isPrimaryKey: false)],
                "orders": [DBColumn(name: "total", dataTypeName: "numeric", isPrimaryKey: false)],
            ])
    }

    private func labels(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        return SQLCompletion.items(text: text, line: lines.count, col: lines.last!.count + 1, schema: schema).map(\.label)
    }

    @Test func tablesAfterFrom() {
        let l = labels("SELECT * FROM ")
        #expect(l == ["users", "orders"])
        #expect(labels("select * from users join o") == ["users", "orders"] || labels("select * from users join o").contains("orders"))
    }

    @Test func columnsAfterAliasDot() {
        let text = "SELECT u.\nFROM users u"
        let items = SQLCompletion.items(text: text, line: 1, col: 10, schema: schema).map(\.label)
        #expect(items == ["id", "email"])
        let byName = SQLCompletion.items(text: "SELECT orders.", line: 1, col: 15, schema: schema).map(\.label)
        #expect(byName == ["total"])
    }

    @Test func generalContextOffersColumnsTablesAndKeywords() {
        let text = "SELECT  FROM users"
        let l = SQLCompletion.items(text: text, line: 1, col: 8, schema: schema).map(\.label)
        #expect(l.contains("email") && l.contains("orders") && l.contains("WHERE"))
    }

    @Test func tableReferencesAndAliases() {
        let refs = SQLCompletion.tableReferences(in: "select * from public.users as u join orders o on o.id = u.id where 1")
        #expect(refs.map(\.table) == ["public.users", "orders"])
        #expect(refs.map { $0.alias } == ["u", "o"])
        #expect(SQLCompletion.tableReferences(in: "select * from users where id = 1").first?.alias == nil)
    }

    @Test func statementSplittingIgnoresSemicolonsInStringsAndComments() {
        let sql = "select ';' as a; -- x; y\nselect 2;\n/* ; */ select 3"
        let parts = SQLStatementSplitter.statements(in: sql).map(\.text)
        #expect(parts.count == 3)
        #expect(parts[0] == "select ';' as a")
        #expect(parts[2].hasSuffix("select 3"))
    }

    @Test func statementAtCaret() {
        let sql = "select 1;\nselect 2;\nselect 3;"
        #expect(SQLStatementSplitter.statement(in: sql, atOffset: 2) == "select 1")
        #expect(SQLStatementSplitter.statement(in: sql, atOffset: 12) == "select 2")
        #expect(SQLStatementSplitter.statement(in: sql, atOffset: 9) == "select 1")    // right after the `;`
        #expect(SQLStatementSplitter.statement(in: "  ", atOffset: 0) == nil)
        #expect(AppState.utf16Offset(in: sql, line: 2, column: 3) == 12)
    }

    @Test func historyDedupesAndCaps() {
        var list: [SQLHistoryEntry] = []
        let d = Date()
        list = SQLHistory.adding(SQLHistoryEntry(sql: " select 1 ", connectionName: "c", date: d), to: list)
        list = SQLHistory.adding(SQLHistoryEntry(sql: "select 1", connectionName: "c", date: d), to: list)
        #expect(list.count == 1 && list[0].sql == "select 1")
        list = SQLHistory.adding(SQLHistoryEntry(sql: "select 2", connectionName: "c", date: d), to: list)
        #expect(list.map(\.sql) == ["select 2", "select 1"])
        #expect(SQLHistory.adding(SQLHistoryEntry(sql: "  ", connectionName: "c", date: d), to: list).count == 2)
        for i in 0..<300 { list = SQLHistory.adding(SQLHistoryEntry(sql: "q\(i)", connectionName: "c", date: d), to: list) }
        #expect(list.count == SQLHistory.maxEntries)
    }
}
