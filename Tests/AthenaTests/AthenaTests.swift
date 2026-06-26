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
