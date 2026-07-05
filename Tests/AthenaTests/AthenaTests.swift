import Testing
import Foundation
@testable import Athena

// MARK: - Language detection

@Suite("Language Detection")
struct LanguageDetectionTests {
    @Test func detectSwift() {
        let url = URL(fileURLWithPath: "/tmp/main.swift")
        #expect(Language.detect(from: url) == .swift)
    }

    @Test func detectTypeScript() {
        let url = URL(fileURLWithPath: "/tmp/app.ts")
        #expect(Language.detect(from: url) == .typescript)
    }

    @Test func detectTSX() {
        let url = URL(fileURLWithPath: "/tmp/App.tsx")
        #expect(Language.detect(from: url) == .typescript)
    }

    @Test func detectUnknown() {
        let url = URL(fileURLWithPath: "/tmp/binary.exe")
        #expect(Language.detect(from: url) == .plaintext)
    }
}

// MARK: - TabModel

@Suite("TabModel")
struct TabModelTests {
    @Test func untitledTab() {
        let tab = TabModel.untitled()
        #expect(tab.title == "Untitled")
        #expect(tab.isDirty == false)
        #expect(tab.content == "")
    }
}

// MARK: - GitStatus

@Suite("GitStatus")
struct GitStatusTests {
    @Test func emptyStatusIsClean() {
        let status = GitStatus()
        #expect(status.isClean)
    }

    @Test func statusWithStagedIsNotClean() {
        var status = GitStatus()
        status.staged = [GitFileChange(path: "foo.swift", status: "M")]
        #expect(!status.isClean)
    }
}

// MARK: - KeychainService

@Suite("KeychainService")
struct KeychainServiceTests {

    @Test func accountNamespacingIsStableAndDistinct() {
        let id = UUID()
        #expect(KeychainService.dbPassword(id)   == "db.\(id.uuidString)")
        #expect(KeychainService.sfccPassword(id) == "sfcc.\(id.uuidString)")
        #expect(KeychainService.dbPassword(id)   != KeychainService.sfccPassword(id))
    }

    @Test func missingAccountReturnsNil() async {
        let keychain = KeychainService()
        let value = await keychain.get(account: "absent.\(UUID().uuidString)")
        #expect(value == nil)
    }

    @Test func roundTripSetGetOverwriteDelete() async throws {
        let keychain = KeychainService()
        let account  = "test.\(UUID().uuidString)"

        // A headless/unsigned environment may reject keychain writes; if the
        // first write fails there is nothing meaningful to assert, so bail out
        // rather than fail the suite spuriously.
        do {
            try await keychain.set("hunter2", account: account)
        } catch {
            return
        }

        #expect(await keychain.get(account: account) == "hunter2")

        // Overwriting an existing item replaces the value.
        try await keychain.set("swordfish", account: account)
        #expect(await keychain.get(account: account) == "swordfish")

        // Setting an empty value removes the item.
        try await keychain.set("", account: account)
        #expect(await keychain.get(account: account) == nil)

        // Deleting an absent item is not an error.
        try await keychain.delete(account: account)
    }
}

// MARK: - Secret redaction in persisted connections

@Suite("Connection secret redaction")
struct ConnectionCodableTests {

    @Test func dbPasswordIsNeverEncoded() throws {
        var conn = DBConnection(name: "local", type: .postgresql)
        conn.password = "s3cret-db"
        let json = String(decoding: try JSONEncoder().encode(conn), as: UTF8.self)
        #expect(!json.contains("s3cret-db"))
        #expect(!json.contains("password"))
        #expect(json.contains("local"))   // non-secret fields still persist
    }

    @Test func sfccPasswordIsNeverEncoded() throws {
        var conn = SFCCConnection(name: "dev01", hostname: "dev01.demandware.net")
        conn.password = "s3cret-sfcc"
        let json = String(decoding: try JSONEncoder().encode(conn), as: UTF8.self)
        #expect(!json.contains("s3cret-sfcc"))
        #expect(!json.contains("password"))
        #expect(json.contains("dev01.demandware.net"))
    }

    @Test func dbConnectionDecodesLegacyInlinePassword() throws {
        // Older builds stored the password inline. Decoding must still read it
        // so the first launch can migrate it into the Keychain.
        let legacy: [String: Any] = [
            "id": UUID().uuidString, "name": "x", "type": "PostgreSQL",
            "host": "localhost", "port": 5432, "database": "app",
            "username": "u", "password": "legacy-pw", "isConnected": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let conn = try JSONDecoder().decode(DBConnection.self, from: data)
        #expect(conn.password == "legacy-pw")
        #expect(conn.name == "x")
        #expect(conn.type == .postgresql)
    }

    @Test func dbConnectionRoundTripDropsPassword() throws {
        var conn = DBConnection(name: "local", type: .mysql)
        conn.password = "drop-me"
        conn.database = "shop"
        let encoded = try JSONEncoder().encode(conn)
        let decoded = try JSONDecoder().decode(DBConnection.self, from: encoded)
        #expect(decoded.password == "")          // gone from disk
        #expect(decoded.database == "shop")       // everything else survives
        #expect(decoded.type == .mysql)
    }
}

// MARK: - Drizzle completions

@Suite("DrizzleCompletionService")
struct DrizzleCompletionTests {

    private func ts(_ name: String = "app.ts") -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    @Test func nonDrizzleFileYieldsNothing() async {
        let svc = DrizzleCompletionService()
        let items = await svc.complete(text: "const x = 1", line: 1, col: 12, fileURL: ts())
        #expect(items.isEmpty)
    }

    @Test func schemaFileIsAlwaysDrizzleContext() async {
        let svc = DrizzleCompletionService()
        let items = await svc.complete(text: "", line: 1, col: 1, fileURL: ts("schema.ts"))
        #expect(!items.isEmpty)
    }

    @Test func dbDotSuggestsQueryBuilder() async {
        let svc = DrizzleCompletionService()
        let text = "import { eq } from 'drizzle-orm'\nawait db."
        let items = await svc.complete(text: text, line: 2, col: 10, fileURL: ts())
        #expect(items.contains { $0.label == "select" })
        #expect(items.contains { $0.label == "insert" })
    }

    @Test func columnContextSuggestsColumnTypes() async {
        let svc = DrizzleCompletionService()
        let text = "from 'drizzle-orm/pg-core'\npgTable("
        let items = await svc.complete(text: text, line: 2, col: 9, fileURL: ts())
        #expect(items.contains { $0.label == "varchar" })
        #expect(items.contains { $0.label == "timestamp" })
    }

    @Test func whereContextSuggestsOperatorsAndFunctions() async {
        let svc = DrizzleCompletionService()
        let text = "from 'drizzle-orm'\n.where("
        let items = await svc.complete(text: text, line: 2, col: 8, fileURL: ts())
        #expect(items.contains { $0.label == "eq" })    // operator
        #expect(items.contains { $0.label == "count" }) // sql function
    }
}

// MARK: - ImportResolver

@Suite("ImportResolver")
struct ImportResolverTests {

    @Test func barePackageImportResolvesToNil() async {
        let resolver = ImportResolver()
        let result = await resolver.resolve(
            "react",
            from: URL(fileURLWithPath: "/tmp/a.ts"),
            workspaceURL: nil
        )
        #expect(result == nil)
    }

    @Test func relativeImportResolvesWithAppendedExtension() async throws {
        let fm  = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("athena-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let util = dir.appendingPathComponent("util.ts")
        try Data("export const x = 1".utf8).write(to: util)

        let resolver = ImportResolver()
        let result = await resolver.resolve(
            "./util",
            from: dir.appendingPathComponent("main.ts"),
            workspaceURL: dir
        )
        #expect(result?.standardizedFileURL == util.standardizedFileURL)
    }

    @Test func directoryImportResolvesToIndexFile() async throws {
        let fm  = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("athena-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("utils")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let index = sub.appendingPathComponent("index.ts")
        try Data("export {}".utf8).write(to: index)

        let resolver = ImportResolver()
        let result = await resolver.resolve(
            "./utils",
            from: dir.appendingPathComponent("main.ts"),
            workspaceURL: dir
        )
        #expect(result?.standardizedFileURL == index.standardizedFileURL)
    }
}

// MARK: - FileWatchService

@Suite("FileWatchService")
struct FileWatchServiceTests {

    /// Collects events off the actor so tests can poll them without racing
    /// the `for await` consumer loop against `#expect`.
    private actor EventCollector {
        private(set) var events: [FileWatchEvent] = []
        func append(_ event: FileWatchEvent) { events.append(event) }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("athena-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Polls `condition` for up to `timeout`, sleeping briefly between
    /// checks — avoids both a flaky fixed `sleep` and hanging forever if a
    /// DispatchSource event never fires.
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    @Test func watchedFileWriteYieldsFileChanged() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("v1".utf8).write(to: file)

        let service = FileWatchService()
        let collector = EventCollector()
        let consumer = Task {
            for await event in await service.eventStream() { await collector.append(event) }
        }
        defer { consumer.cancel() }

        await service.watchFile(file)
        // In-place (non-atomic) write — keeps the same inode, so this should
        // surface as `.write`, not a rename-over-original.
        try Data("v2".utf8).write(to: file, options: [])

        let sawChange = await waitUntil {
            await collector.events.contains(.fileChanged(file))
        }
        #expect(sawChange)
    }

    @Test func watchedFileDeleteYieldsFileDeleted() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("b.txt")
        try Data("v1".utf8).write(to: file)

        let service = FileWatchService()
        let collector = EventCollector()
        let consumer = Task {
            for await event in await service.eventStream() { await collector.append(event) }
        }
        defer { consumer.cancel() }

        await service.watchFile(file)
        try FileManager.default.removeItem(at: file)

        let sawDelete = await waitUntil {
            await collector.events.contains(.fileDeleted(file))
        }
        #expect(sawDelete)
    }

    @Test func stoppedWatchYieldsNoFurtherEvents() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("c.txt")
        try Data("v1".utf8).write(to: file)

        let service = FileWatchService()
        let collector = EventCollector()
        let consumer = Task {
            for await event in await service.eventStream() { await collector.append(event) }
        }
        defer { consumer.cancel() }

        await service.watchFile(file)
        await service.stopWatchingFile(file)
        try Data("v2".utf8).write(to: file, options: [])

        // Bounded wait for an event that should never arrive; short because
        // we're proving an absence, not racing a real one.
        let sawChange = await waitUntil(timeout: .milliseconds(500)) {
            await collector.events.contains(.fileChanged(file))
        }
        #expect(!sawChange)
    }

    @Test func watchedDirectoryEntryYieldsDirectoryChanged() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = FileWatchService()
        let collector = EventCollector()
        let consumer = Task {
            for await event in await service.eventStream() { await collector.append(event) }
        }
        defer { consumer.cancel() }

        await service.watchDirectory(dir)
        try Data("new".utf8).write(to: dir.appendingPathComponent("new.txt"))

        let sawChange = await waitUntil {
            await collector.events.contains(.directoryChanged(dir))
        }
        #expect(sawChange)
    }
}

// MARK: - TextSearchMatcher

@Suite("TextSearchMatcher")
struct TextSearchMatcherTests {

    @Test func literalMatchesAreCaseInsensitiveByDefault() {
        let matcher = TextSearchMatcher(query: "foo", isRegex: false, caseSensitive: false, wholeWord: false)!
        let ranges = matcher.matches(in: "Foo bar foo BAZ fOO")
        #expect(ranges.count == 3)
    }

    @Test func caseSensitiveLiteralNarrowsMatches() {
        let matcher = TextSearchMatcher(query: "foo", isRegex: false, caseSensitive: true, wholeWord: false)!
        let ranges = matcher.matches(in: "Foo bar foo BAZ fOO")
        #expect(ranges.count == 1)
        #expect(ranges[0] == NSRange(location: 8, length: 3))
    }

    @Test func wholeWordExcludesSubstringMatches() {
        let matcher = TextSearchMatcher(query: "cat", isRegex: false, caseSensitive: true, wholeWord: true)!
        let ranges = matcher.matches(in: "cat concatenate cat")
        #expect(ranges.count == 2)
    }

    @Test func regexSpecialCharsAreLiteralWhenNotRegex() {
        let matcher = TextSearchMatcher(query: "a.b", isRegex: false, caseSensitive: true, wholeWord: false)!
        let ranges = matcher.matches(in: "a.b axb a.b")
        #expect(ranges.count == 2)
    }

    @Test func regexModeMatchesPattern() {
        let matcher = TextSearchMatcher(query: "f[oi]o", isRegex: true, caseSensitive: true, wholeWord: false)!
        let ranges = matcher.matches(in: "foo fio fao")
        #expect(ranges.count == 2)
    }

    @Test func invalidRegexFailsToInitialize() {
        let matcher = TextSearchMatcher(query: "(unclosed", isRegex: true, caseSensitive: true, wholeWord: false)
        #expect(matcher == nil)
    }

    @Test func emptyQueryFailsToInitialize() {
        let matcher = TextSearchMatcher(query: "", isRegex: false, caseSensitive: false, wholeWord: false)
        #expect(matcher == nil)
    }

    @Test func replacingAllReplacesEveryLiteralMatch() {
        let matcher = TextSearchMatcher(query: "cat", isRegex: false, caseSensitive: true, wholeWord: false)!
        let (result, count) = matcher.replacingAll(in: "cat sat cat", with: "dog")
        #expect(count == 2)
        #expect(result == "dog sat dog")
    }

    @Test func replacingAllReturnsOriginalWhenNoMatches() {
        let matcher = TextSearchMatcher(query: "zzz", isRegex: false, caseSensitive: true, wholeWord: false)!
        let (result, count) = matcher.replacingAll(in: "cat sat cat", with: "dog")
        #expect(count == 0)
        #expect(result == "cat sat cat")
    }

    @Test func replacingAllHonorsCaptureGroupsInRegexMode() {
        let matcher = TextSearchMatcher(query: "(\\w+)@(\\w+)", isRegex: true, caseSensitive: true, wholeWord: false)!
        let (result, count) = matcher.replacingAll(in: "user@host", with: "$2:$1")
        #expect(count == 1)
        #expect(result == "host:user")
    }

    @Test func replacingAllTreatsReplacementLiterallyWhenNotRegex() {
        // A literal-mode replacement containing "$1" must not be treated as a
        // capture-group template even though the query itself has groups.
        let matcher = TextSearchMatcher(query: "a.b", isRegex: false, caseSensitive: true, wholeWord: false)!
        let (result, count) = matcher.replacingAll(in: "a.b", with: "$1 literally")
        #expect(count == 1)
        #expect(result == "$1 literally")
    }

    @Test func replacementTextForSingleMatchHonorsCaptureGroups() {
        let matcher = TextSearchMatcher(query: "(\\w+)@(\\w+)", isRegex: true, caseSensitive: true, wholeWord: false)!
        let text = "user@host"
        let range = matcher.matches(in: text)[0]
        let replaced = matcher.replacementText(forMatchIn: text, range: range, replacement: "$2:$1")
        #expect(replaced == "host:user")
    }
}

// MARK: - LSP TextEdit application (format-on-save)

@Suite("applyLSPTextEdits")
struct ApplyLSPTextEditsTests {
    @Test func emptyEditsReturnsContentUnchanged() {
        let content = "let x = 1;"
        #expect(applyLSPTextEdits([], to: content) == content)
    }

    @Test func singleReplacementOnOneLine() {
        // "let x=1;" -> replace "x=1" with "x = 1"
        let content = "let x=1;"
        let edit = LSPTextEdit(startLine: 0, startCharacter: 4, endLine: 0, endCharacter: 7, newText: "x = 1")
        #expect(applyLSPTextEdits([edit], to: content) == "let x = 1;")
    }

    @Test func multipleEditsOnSameLineApplyInDescendingOrderWithoutInvalidatingOffsets() {
        // Two independent single-character insertions on the same line — if
        // applied in ascending (document) order without adjusting offsets,
        // the second edit's stale offset would land in the wrong place after
        // the first edit changes the string's length.
        let content = "ab"
        let insertAfterA = LSPTextEdit(startLine: 0, startCharacter: 1, endLine: 0, endCharacter: 1, newText: "X")
        let insertAfterB = LSPTextEdit(startLine: 0, startCharacter: 2, endLine: 0, endCharacter: 2, newText: "Y")
        let result = applyLSPTextEdits([insertAfterA, insertAfterB], to: content)
        #expect(result == "aXbY")
    }

    @Test func editSpanningMultipleLines() {
        let content = "line1\nline2\nline3"
        // Replace "line2" entirely with "REPLACED"
        let edit = LSPTextEdit(startLine: 1, startCharacter: 0, endLine: 1, endCharacter: 5, newText: "REPLACED")
        #expect(applyLSPTextEdits([edit], to: content) == "line1\nREPLACED\nline3")
    }

    @Test func deletionEditRemovesRange() {
        let content = "foo bar baz"
        // Remove " bar" (characters 3..7)
        let edit = LSPTextEdit(startLine: 0, startCharacter: 3, endLine: 0, endCharacter: 7, newText: "")
        #expect(applyLSPTextEdits([edit], to: content) == "foo baz")
    }

    @Test func wholeDocumentReplacement() {
        let content = "const x=1\nconst y=2\n"
        let edit = LSPTextEdit(
            startLine: 0, startCharacter: 0,
            endLine: 2, endCharacter: 0,
            newText: "const x = 1;\nconst y = 2;\n"
        )
        #expect(applyLSPTextEdits([edit], to: content) == "const x = 1;\nconst y = 2;\n")
    }
}

// MARK: - Document Symbols (Go to Symbol / Outline / Breadcrumbs)

@Suite("flattenDocumentSymbols")
struct FlattenDocumentSymbolsTests {
    private func symbol(
        _ name: String,
        line: Int = 1,
        rangeStart: Int = 1,
        rangeEnd: Int = 1,
        children: [DocumentSymbol]? = nil
    ) -> DocumentSymbol {
        DocumentSymbol(
            name: name, kind: 12, line: line, character: 1,
            rangeStartLine: rangeStart, rangeEndLine: rangeEnd, children: children
        )
    }

    @Test func emptyTreeYieldsEmptyList() {
        #expect(flattenDocumentSymbols([]).isEmpty)
    }

    @Test func flatTreeYieldsDepthZeroForEveryEntry() {
        let symbols = [symbol("a"), symbol("b")]
        let flattened = flattenDocumentSymbols(symbols)
        #expect(flattened.map(\.symbol.name) == ["a", "b"])
        #expect(flattened.allSatisfy { $0.depth == 0 })
    }

    @Test func nestedTreeIsDepthFirstWithIncreasingDepth() {
        let grandchild = symbol("grandchild")
        let child = symbol("child", children: [grandchild])
        let sibling = symbol("sibling")
        let root = symbol("root", children: [child, sibling])

        let flattened = flattenDocumentSymbols([root])
        #expect(flattened.map(\.symbol.name) == ["root", "child", "grandchild", "sibling"])
        #expect(flattened.map(\.depth) == [0, 1, 2, 1])
    }
}

@Suite("breadcrumbSymbolPath")
struct BreadcrumbSymbolPathTests {
    private func symbol(
        _ name: String,
        rangeStart: Int,
        rangeEnd: Int,
        children: [DocumentSymbol]? = nil
    ) -> DocumentSymbol {
        DocumentSymbol(
            name: name, kind: 5, line: rangeStart, character: 1,
            rangeStartLine: rangeStart, rangeEndLine: rangeEnd, children: children
        )
    }

    @Test func lineOutsideEverySymbolYieldsEmptyPath() {
        let symbols = [symbol("Foo", rangeStart: 1, rangeEnd: 10)]
        #expect(breadcrumbSymbolPath(in: symbols, containingLine: 20).isEmpty)
    }

    @Test func lineInsideOuterOnlyYieldsSingleSegment() {
        let method = symbol("bar", rangeStart: 3, rangeEnd: 5)
        let outer = symbol("Foo", rangeStart: 1, rangeEnd: 10, children: [method])
        let path = breadcrumbSymbolPath(in: [outer], containingLine: 8)
        #expect(path.map(\.name) == ["Foo"])
    }

    @Test func lineInsideNestedSymbolYieldsFullChain() {
        let method = symbol("bar", rangeStart: 3, rangeEnd: 5)
        let outer = symbol("Foo", rangeStart: 1, rangeEnd: 10, children: [method])
        let path = breadcrumbSymbolPath(in: [outer], containingLine: 4)
        #expect(path.map(\.name) == ["Foo", "bar"])
    }

    @Test func deepestSiblingMatchWinsAtEachLevel() {
        // Two top-level symbols; the line falls inside the second one only.
        let first  = symbol("First",  rangeStart: 1, rangeEnd: 5)
        let second = symbol("Second", rangeStart: 6, rangeEnd: 10)
        let path = breadcrumbSymbolPath(in: [first, second], containingLine: 7)
        #expect(path.map(\.name) == ["Second"])
    }
}
