import Testing
import Foundation
import AppKit
import os
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

    // plan.md item 26 ("G1") — image extensions NSImage loads natively.
    @Test func detectImagePNG() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/photo.png")) == .image)
    }

    @Test func detectImageJPEG() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/photo.jpg")) == .image)
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/photo.jpeg")) == .image)
    }

    @Test func detectImageOtherFormats() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/anim.gif")) == .image)
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/pic.webp")) == .image)
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/icon.svg")) == .image)
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/scan.bmp")) == .image)
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/scan.tiff")) == .image)
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/scan.tif")) == .image)
    }

    @Test func detectImageIsCaseInsensitive() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/PHOTO.PNG")) == .image)
    }

    @Test func detectMarkdown() {
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/notes.md")) == .markdown)
        #expect(Language.detect(from: URL(fileURLWithPath: "/tmp/README.markdown")) == .markdown)
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

    // plan.md item 26 ("G2") — markdown Source/Preview defaults to Source.
    @Test func defaultsToSourceNotPreview() {
        let tab = TabModel.untitled()
        #expect(tab.isMarkdownPreview == false)
    }
}

// MARK: - TabModel.nextActiveId

/// `TabModel.nextActiveId` (plan.md item 22) is the pure-function seam the
/// split-editor refactor introduced — shared by `AppState.closeTab`'s
/// primary- and secondary-group cases so "which tab activates next" can't
/// drift between the two panes. Mirrors `TerminalSessionNextActiveIdTests`
/// exactly, since it's the same rule applied to a different tab type.
@Suite("TabModel.nextActiveId")
struct TabModelNextActiveIdTests {
    private func tab(_ title: String) -> TabModel {
        TabModel(title: title)
    }

    @Test func closingNonActiveTabLeavesActiveIdUnchanged() {
        let a = tab("a"), b = tab("b"), c = tab("c")
        let result = TabModel.nextActiveId(
            afterClosing: b.id, in: [a, b, c], previousActiveId: a.id
        )
        #expect(result == a.id)
    }

    @Test func closingActiveTabPrefersTheOneNowAtTheSameIndex() {
        // [a, b, c] closing b (index 1) -> c is now at index 1.
        let a = tab("a"), b = tab("b"), c = tab("c")
        let result = TabModel.nextActiveId(
            afterClosing: b.id, in: [a, b, c], previousActiveId: b.id
        )
        #expect(result == c.id)
    }

    @Test func closingActiveLastTabFallsBackToTheNewLastOne() {
        // [a, b, c] closing c (index 2, out of bounds after removal) -> b.
        let a = tab("a"), b = tab("b"), c = tab("c")
        let result = TabModel.nextActiveId(
            afterClosing: c.id, in: [a, b, c], previousActiveId: c.id
        )
        #expect(result == b.id)
    }

    @Test func closingTheOnlyTabLeavesNoActiveTab() {
        let a = tab("a")
        let result = TabModel.nextActiveId(
            afterClosing: a.id, in: [a], previousActiveId: a.id
        )
        #expect(result == nil)
    }

    @Test func closingAnIdNotInTheListLeavesActiveIdUnchanged() {
        let a = tab("a"), b = tab("b")
        let bogusId = UUID()
        let result = TabModel.nextActiveId(
            afterClosing: bogusId, in: [a, b], previousActiveId: a.id
        )
        #expect(result == a.id)
    }

    @Test func previousActiveIdNilStaysNilWhenClosingAnUnrelatedTab() {
        let a = tab("a"), b = tab("b")
        let result = TabModel.nextActiveId(
            afterClosing: a.id, in: [a, b], previousActiveId: nil
        )
        #expect(result == nil)
    }
}

// MARK: - EditorGroupSide

@Suite("EditorGroupSide")
struct EditorGroupSideTests {
    @Test func otherOfPrimaryIsSecondary() {
        #expect(EditorGroupSide.primary.other == .secondary)
    }

    @Test func otherOfSecondaryIsPrimary() {
        #expect(EditorGroupSide.secondary.other == .primary)
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

// MARK: - SFCC upload paths + log records

@Suite("SFCC upload")
struct SFCCUploadTests {

    private let workspace = URL(fileURLWithPath: "/Users/dev/shop")

    private func conn(cartridgesPath: String = "cartridges") -> SFCCConnection {
        var c = SFCCConnection(name: "dev01", hostname: "dev01.demandware.net")
        c.cartridgesPath = cartridgesPath
        return c
    }

    @Test func relativePathInsideRelativeRoot() throws {
        let file = URL(fileURLWithPath: "/Users/dev/shop/cartridges/app_custom/cartridge/templates/default/home.isml")
        let rel = try SFCCService.cartridgeRelativePath(for: file, connection: conn(), workspaceURL: workspace)
        #expect(rel == "app_custom/cartridge/templates/default/home.isml")
    }

    @Test func relativePathInsideAbsoluteRoot() throws {
        let file = URL(fileURLWithPath: "/opt/carts/app_custom/x.js")
        let rel = try SFCCService.cartridgeRelativePath(
            for: file, connection: conn(cartridgesPath: "/opt/carts"), workspaceURL: workspace)
        #expect(rel == "app_custom/x.js")
    }

    @Test func fileOutsideRootThrows() {
        let file = URL(fileURLWithPath: "/Users/dev/shop/package.json")
        #expect(throws: SFCCError.self) {
            try SFCCService.cartridgeRelativePath(for: file, connection: conn(), workspaceURL: workspace)
        }
    }

    // A sibling directory sharing the root's name as a prefix must not match —
    // `hasPrefix` on the bare root path used to accept "cartridges-backup".
    @Test func siblingPrefixDirectoryDoesNotMatch() {
        let file = URL(fileURLWithPath: "/Users/dev/shop/cartridges-backup/app_custom/x.js")
        #expect(throws: SFCCError.self) {
            try SFCCService.cartridgeRelativePath(for: file, connection: conn(), workspaceURL: workspace)
        }
    }

    @Test func uploadRecordRoundTripsFailureMessage() throws {
        let record = SFCCUploadRecord(
            date: Date(), relativePath: "app_custom/cartridge/scripts/cart.js",
            connectionName: "dev01", codeVersion: "version1",
            kind: .upload, status: .failure("SFCC HTTP 401")
        )
        let decoded = try JSONDecoder().decode(
            SFCCUploadRecord.self, from: try JSONEncoder().encode(record))
        #expect(decoded.status == .failure("SFCC HTTP 401"))
        #expect(decoded.failureMessage == "SFCC HTTP 401")
        #expect(decoded.fileName == "cart.js")
        #expect(decoded.kind == .upload)
    }
}

// MARK: - SFCC cartridge watch (FSEvents)

@Suite("SFCCWatchService")
struct SFCCWatchTests {

    @Test func transientSaveArtifactsAreFiltered() {
        // macOS safe-save temp from an atomic write (seen uploading in the wild).
        #expect(SFCCWatchService.isTransientArtifact("Account.js.sb-7d048152-kraYKs"))
        #expect(SFCCWatchService.isTransientArtifact("Account.js.tmp"))
        #expect(SFCCWatchService.isTransientArtifact("Account.js~"))

        #expect(!SFCCWatchService.isTransientArtifact("Account.js"))
        #expect(!SFCCWatchService.isTransientArtifact("home.isml"))
        // ".sb-" mid-name without the temp shape is a real file.
        #expect(!SFCCWatchService.isTransientArtifact("logo.sb-header.svg"))
    }

    @Test func detectsFileCreationRecursively() async throws {
        let fm  = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("athena-sfcc-watch-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("app_custom/cartridge/templates")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let service = SFCCWatchService()
        let events  = await service.start(watching: dir)

        // Give FSEvents a beat to arm before the write it must observe.
        let clock = ContinuousClock()
        try await clock.sleep(until: clock.now.advanced(by: .milliseconds(300)))
        try Data("<iscontent/>".utf8).write(to: sub.appendingPathComponent("home.isml"))

        // First batch vs. 10 s timeout, whichever wins. Compare only the last
        // path component: /var/folders/… symlinks to /private/var/… and
        // FSEvents reports the resolved path.
        let batch = await withTaskGroup(of: [URL]?.self) { group -> [URL]? in
            group.addTask {
                for await batch in events { return batch }
                return nil
            }
            group.addTask {
                try? await clock.sleep(until: clock.now.advanced(by: .seconds(10)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await service.stop()

        #expect(batch?.contains { $0.lastPathComponent == "home.isml" } == true)
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

// MARK: - TextSearchMatcher

// FileWatchServiceTests moved to its own test target,
// Tests/AthenaFileWatchTests/FileWatchServiceTests.swift — see that file's
// header comment for why (process-isolation from this suite's contention).

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

// MARK: - Sticky Scroll (plan.md item 28, "G3")

@Suite("stickyScrollRows")
struct StickyScrollRowsTests {
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

    @Test func lineOutsideEverySymbolYieldsNoRows() {
        let symbols = [symbol("Foo", rangeStart: 1, rangeEnd: 10)]
        #expect(stickyScrollRows(in: symbols, topVisibleLine: 20).isEmpty)
    }

    @Test func headerLineStillVisibleYieldsNoRow() {
        // The symbol's own opening line IS the top-visible line — already
        // on screen, so no sticky row should be pinned for it.
        let outer = symbol("Foo", rangeStart: 1, rangeEnd: 10)
        #expect(stickyScrollRows(in: [outer], topVisibleLine: 1).isEmpty)
    }

    @Test func headerScrolledAboveViewportYieldsOneRow() {
        let outer = symbol("Foo", rangeStart: 1, rangeEnd: 10)
        let rows = stickyScrollRows(in: [outer], topVisibleLine: 5)
        #expect(rows.map(\.name) == ["Foo"])
    }

    @Test func nestedScopesBothScrolledOffYieldFullChainOutermostFirst() {
        let method = symbol("bar", rangeStart: 3, rangeEnd: 8)
        let outer  = symbol("Foo", rangeStart: 1, rangeEnd: 10, children: [method])
        let rows = stickyScrollRows(in: [outer], topVisibleLine: 6)
        #expect(rows.map(\.name) == ["Foo", "bar"])
    }

    @Test func innerScopeHeaderStillVisibleDropsOnlyThatRow() {
        // Top-visible line sits exactly on `bar`'s own header line: `bar`
        // shouldn't get a row (already visible), but the still-enclosing
        // `Foo` (scrolled off) should.
        let method = symbol("bar", rangeStart: 3, rangeEnd: 8)
        let outer  = symbol("Foo", rangeStart: 1, rangeEnd: 10, children: [method])
        let rows = stickyScrollRows(in: [outer], topVisibleLine: 3)
        #expect(rows.map(\.name) == ["Foo"])
    }

    @Test func chainLongerThanMaxLevelsKeepsDeepestEntries() {
        let level4 = symbol("d", rangeStart: 4, rangeEnd: 20)
        let level3 = symbol("c", rangeStart: 3, rangeEnd: 21, children: [level4])
        let level2 = symbol("b", rangeStart: 2, rangeEnd: 22, children: [level3])
        let level1 = symbol("a", rangeStart: 1, rangeEnd: 23, children: [level2])
        let rows = stickyScrollRows(in: [level1], topVisibleLine: 10, maxLevels: 2)
        #expect(rows.map(\.name) == ["c", "d"])
    }

    @Test func maxLevelsLargerThanChainReturnsWholeChain() {
        let method = symbol("bar", rangeStart: 3, rangeEnd: 8)
        let outer  = symbol("Foo", rangeStart: 1, rangeEnd: 10, children: [method])
        let rows = stickyScrollRows(in: [outer], topVisibleLine: 6, maxLevels: 10)
        #expect(rows.map(\.name) == ["Foo", "bar"])
    }
}

@Suite("firstVisibleLine")
struct FirstVisibleLineTests {
    @Test func zeroLineCountReturnsLineOne() {
        #expect(firstVisibleLine(lineCount: 0, scrollFraction: 0.5, visibleFraction: 0.2) == 1)
    }

    @Test func unscrolledDocumentReturnsLineOne() {
        #expect(firstVisibleLine(lineCount: 100, scrollFraction: 0, visibleFraction: 0.2) == 1)
    }

    @Test func fullyScrolledDocumentReturnsLineAfterLastVisiblePage() {
        // 100 lines, viewport shows 20% (20 lines) — fully scrolled puts the
        // top-visible line at the start of the final page (line 81, 1-based).
        #expect(firstVisibleLine(lineCount: 100, scrollFraction: 1.0, visibleFraction: 0.2) == 81)
    }

    @Test func halfwayScrolledDocumentLandsMidway() {
        // 100 lines, 20-line viewport: scrollable range is 80 lines, halfway
        // is +40, landing on line 41 (1-based).
        #expect(firstVisibleLine(lineCount: 100, scrollFraction: 0.5, visibleFraction: 0.2) == 41)
    }

    @Test func visibleFractionCoveringWholeDocumentNeverScrolls() {
        // Viewport shows the entire document (visibleFraction 1.0) — no room
        // to scroll, so the top-visible line stays 1 regardless of fraction.
        #expect(firstVisibleLine(lineCount: 50, scrollFraction: 1.0, visibleFraction: 1.0) == 1)
    }

    @Test func outOfRangeFractionsAreClamped() {
        #expect(firstVisibleLine(lineCount: 100, scrollFraction: 1.5, visibleFraction: 0.2)
                == firstVisibleLine(lineCount: 100, scrollFraction: 1.0, visibleFraction: 0.2))
        #expect(firstVisibleLine(lineCount: 100, scrollFraction: -0.5, visibleFraction: 0.2)
                == firstVisibleLine(lineCount: 100, scrollFraction: 0.0, visibleFraction: 0.2))
    }
}

// MARK: - Snippet Engine (plan.md item 16, "B5")

@Suite("SnippetEngine")
struct SnippetEngineTests {

    @Test func plainTextWithNoMarkersYieldsNoTabStops() {
        let expanded = SnippetEngine.expand("select()")
        #expect(expanded.text == "select()")
        #expect(expanded.tabStops.isEmpty)
    }

    @Test func placeholderAndPlainStopOrderedWithImplicitFinalStopLast() {
        // From the task brief: parse `"foo(${1:a}, $2)$0"` into plain text
        // plus ordered tab-stop ranges.
        let expanded = SnippetEngine.expand("foo(${1:a}, $2)$0")
        #expect(expanded.text == "foo(a, )")
        #expect(expanded.tabStops.map(\.index) == [1, 2, 0])
        #expect(expanded.tabStops[0].range == NSRange(location: 4, length: 1)) // "a"
        #expect(expanded.tabStops[1].range == NSRange(location: 7, length: 0)) // between ", " and ")"
        #expect(expanded.tabStops[2].range == NSRange(location: 8, length: 0)) // end of "foo(a, )"
    }

    @Test func stopsAreOrderedNumericallyRegardlessOfSourceOrder() {
        let expanded = SnippetEngine.expand("$2 then $1")
        #expect(expanded.tabStops.map(\.index) == [1, 2, 0])
    }

    @Test func placeholderTextIsCapturedAsTheStopsRange() {
        let expanded = SnippetEngine.expand("${1:hello}")
        #expect(expanded.text == "hello")
        #expect(expanded.tabStops.map(\.index) == [1, 0])
        #expect(expanded.tabStops[0].range == NSRange(location: 0, length: 5))
        #expect(expanded.tabStops[1].range == NSRange(location: 5, length: 0)) // implicit $0 at end
    }

    @Test func bracedStopWithoutColonHasEmptyPlaceholder() {
        let expanded = SnippetEngine.expand("(${1})")
        #expect(expanded.text == "()")
        #expect(expanded.tabStops.map(\.index) == [1, 0])
        #expect(expanded.tabStops[0].range == NSRange(location: 1, length: 0))
    }

    @Test func explicitFinalStopIsNotDuplicated() {
        // "$0" appears once in the source; there should be exactly one
        // final-stop entry, not an extra implicit one appended after it.
        let expanded = SnippetEngine.expand("a$0b")
        #expect(expanded.text == "ab")
        #expect(expanded.tabStops.count == 1)
        #expect(expanded.tabStops[0].index == 0)
        #expect(expanded.tabStops[0].range == NSRange(location: 1, length: 0))
    }

    @Test func implicitFinalStopDefaultsToEndOfExpandedText() {
        let expanded = SnippetEngine.expand("$1")
        #expect(expanded.text.isEmpty)
        #expect(expanded.tabStops.map(\.index) == [1, 0])
        #expect(expanded.tabStops[1].range == NSRange(location: 0, length: 0))
    }

    @Test func trailingDollarWithNoDigitsIsLiteral() {
        let expanded = SnippetEngine.expand("cost: $")
        #expect(expanded.text == "cost: $")
        #expect(expanded.tabStops.isEmpty)
    }

    @Test func malformedBraceFallsBackToLiteralTextWithoutCrashing() {
        // Unterminated `${1:abc` (no closing `}`) — not well-formed, so the
        // whole thing is emitted verbatim rather than partially consumed.
        let expanded = SnippetEngine.expand("${1:abc")
        #expect(expanded.text == "${1:abc")
        #expect(expanded.tabStops.isEmpty)
    }

    @Test func multipleNumberedStopsWithSharedPrefixDigitsParseIndependently() {
        let expanded = SnippetEngine.expand("${10:ten} $2")
        #expect(expanded.tabStops.map(\.index) == [2, 10, 0])
    }
}

// MARK: - Line Operations (plan.md item 17, "B7")

/// Applies a `LineOperations.Edit` to `text` the same way
/// `EditorView.Coordinator.replace(_:with:in:selecting:)` applies it to a
/// real `NSTextView`, so tests can assert on the resulting whole-document
/// text rather than just the raw edit description.
private func apply(_ edit: LineOperations.Edit, to text: String) -> String {
    (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
}

@Suite("LineOperations — Move Line Up/Down")
struct LineOperationsMoveTests {

    @Test func moveMiddleLineUpSwapsWithPrevious() {
        let text = "AAA\nBBB\nCCC"
        let caret = NSRange(location: 9, length: 0) // inside "CCC"
        let edit = LineOperations.moveUp(text: text, selection: caret)
        #expect(edit != nil)
        #expect(apply(edit!, to: text) == "AAA\nCCC\nBBB")
        #expect(edit!.newSelection == NSRange(location: 5, length: 0))
    }

    @Test func moveMiddleLineDownSwapsWithNext() {
        let text = "AAA\nBBB\nCCC"
        let caret = NSRange(location: 5, length: 0) // inside "BBB"
        let edit = LineOperations.moveDown(text: text, selection: caret)
        #expect(edit != nil)
        #expect(apply(edit!, to: text) == "AAA\nCCC\nBBB")
    }

    @Test func moveUpAtTopOfFileIsNoOp() {
        let text = "AAA\nBBB"
        let caret = NSRange(location: 1, length: 0) // inside "AAA", the first line
        #expect(LineOperations.moveUp(text: text, selection: caret) == nil)
    }

    @Test func moveDownAtBottomOfFileWithNoTrailingNewlineIsNoOp() {
        let text = "AAA\nBBB"
        let caret = NSRange(location: 5, length: 0) // inside "BBB", the last line, no trailing \n
        #expect(LineOperations.moveDown(text: text, selection: caret) == nil)
    }

    @Test func moveLastLineWithNoTrailingNewlineUpGainsATerminator() {
        // The moved line is no longer last, so it must gain a "\n"; the line
        // it swapped with becomes last and correctly ends up without one.
        let text = "AAA\nBBB\nCCC"
        let caret = NSRange(location: 8, length: 0) // start of "CCC", the last line
        let edit = LineOperations.moveUp(text: text, selection: caret)
        #expect(edit != nil)
        #expect(apply(edit!, to: text) == "AAA\nCCC\nBBB")
    }

    @Test func moveMultiLineSelectionMovesTheWholeBlock() {
        let text = "AAA\nBBB\nCCC\nDDD"
        // Selection spans "BBB\nCCC" (touches two lines, not just the caret's line).
        let selection = NSRange(location: 5, length: 5)
        let edit = LineOperations.moveDown(text: text, selection: selection)
        #expect(edit != nil)
        #expect(apply(edit!, to: text) == "AAA\nDDD\nBBB\nCCC")
    }

    @Test func moveEmptyFileIsNoOp() {
        #expect(LineOperations.moveUp(text: "", selection: NSRange(location: 0, length: 0)) == nil)
        #expect(LineOperations.moveDown(text: "", selection: NSRange(location: 0, length: 0)) == nil)
    }
}

@Suite("LineOperations — Copy Line Up/Down")
struct LineOperationsCopyTests {

    @Test func copyUpInsertsAboveAndSelectionStaysOnOriginal() {
        // VS Code: Copy Line Up leaves the cursor on the ORIGINAL content,
        // which is now pushed down below the new copy.
        let text = "AAA\nBBB\nCCC"
        let caret = NSRange(location: 5, length: 0) // inside "BBB"
        let edit = LineOperations.copyUp(text: text, selection: caret)
        #expect(apply(edit, to: text) == "AAA\nBBB\nBBB\nCCC")
        #expect(edit.newSelection == NSRange(location: 5 + 4, length: 0)) // shifted down by "BBB\n"
    }

    @Test func copyDownInsertsBelowAndSelectionMovesToTheCopy() {
        // VS Code: Copy Line Down moves the cursor to the NEW copy below.
        let text = "AAA\nBBB\nCCC"
        let caret = NSRange(location: 5, length: 0) // inside "BBB"
        let edit = LineOperations.copyDown(text: text, selection: caret)
        #expect(apply(edit, to: text) == "AAA\nBBB\nBBB\nCCC")
        #expect(edit.newSelection == NSRange(location: 5 + 4, length: 0)) // moved into the copy
    }

    @Test func copyUpOnLastLineWithNoTrailingNewlineAddsASeparator() {
        let text = "AAA\nBBB"
        let caret = NSRange(location: 5, length: 0) // inside "BBB", last line, no trailing \n
        let edit = LineOperations.copyUp(text: text, selection: caret)
        #expect(apply(edit, to: text) == "AAA\nBBB\nBBB")
    }

    @Test func copyDownOnLastLineWithNoTrailingNewlinePreservesNoTrailingNewline() {
        let text = "AAA\nBBB"
        let caret = NSRange(location: 5, length: 0) // inside "BBB", last line, no trailing \n
        let edit = LineOperations.copyDown(text: text, selection: caret)
        #expect(apply(edit, to: text) == "AAA\nBBB\nBBB")
    }

    @Test func copyMultiLineSelectionDuplicatesTheWholeBlock() {
        let text = "AAA\nBBB\nCCC"
        let selection = NSRange(location: 4, length: 4) // "BBB\n"
        let edit = LineOperations.copyDown(text: text, selection: selection)
        #expect(apply(edit, to: text) == "AAA\nBBB\nBBB\nCCC")
    }

    @Test func copySingleLineFileWithNoTrailingNewline() {
        let text = "AAA"
        let caret = NSRange(location: 1, length: 0)
        let edit = LineOperations.copyDown(text: text, selection: caret)
        #expect(apply(edit, to: text) == "AAA\nAAA")
    }
}

@Suite("LineOperations — Delete Line")
struct LineOperationsDeleteTests {

    @Test func deleteMiddleLineLandsCaretAtStartOfFollowingLine() {
        let text = "AAA\nBBB\nCCC"
        let caret = NSRange(location: 5, length: 0) // inside "BBB"
        let edit = LineOperations.deleteLines(text: text, selection: caret)
        #expect(apply(edit, to: text) == "AAA\nCCC")
        #expect(edit.newSelection == NSRange(location: 4, length: 0)) // start of "CCC"
    }

    @Test func deleteLastLineWithNoTrailingNewlineLandsCaretAtEndOfFile() {
        let text = "AAA\nBBB"
        let caret = NSRange(location: 5, length: 0) // inside "BBB", the last line
        let edit = LineOperations.deleteLines(text: text, selection: caret)
        #expect(apply(edit, to: text) == "AAA\n")
        #expect(edit.newSelection == NSRange(location: 4, length: 0))
    }

    @Test func deleteOnlyLineOfSingleLineFileYieldsEmptyText() {
        let text = "AAA"
        let caret = NSRange(location: 1, length: 0)
        let edit = LineOperations.deleteLines(text: text, selection: caret)
        #expect(apply(edit, to: text) == "")
        #expect(edit.newSelection == NSRange(location: 0, length: 0))
    }

    @Test func deleteOnEmptyFileIsHarmlessNoOp() {
        let edit = LineOperations.deleteLines(text: "", selection: NSRange(location: 0, length: 0))
        #expect(apply(edit, to: "") == "")
        #expect(edit.newSelection == NSRange(location: 0, length: 0))
    }

    @Test func deleteMultiLineSelectionRemovesEveryTouchedLine() {
        let text = "AAA\nBBB\nCCC\nDDD"
        let selection = NSRange(location: 5, length: 5) // touches "BBB" and "CCC"
        let edit = LineOperations.deleteLines(text: text, selection: selection)
        #expect(apply(edit, to: text) == "AAA\nDDD")
    }
}

// MARK: - Unified Diff Parser (plan.md item 18, "D2")

@Suite("UnifiedDiffParser")
struct UnifiedDiffParserTests {

    @Test func singleHunkWithContextAddedAndRemovedLinesClassifiedWithCorrectLineNumbers() {
        let diff = """
        diff --git a/foo.txt b/foo.txt
        index 1111111..2222222 100644
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,3 +1,4 @@
         line1
        -line2
        +line2 modified
        +line3 added
         line3
        """
        let parsed = UnifiedDiffParser.parse(diff)
        #expect(parsed.isBinary == false)
        #expect(parsed.hunks.count == 1)

        let hunk = parsed.hunks[0]
        #expect(hunk.oldStart == 1 && hunk.oldCount == 3)
        #expect(hunk.newStart == 1 && hunk.newCount == 4)
        #expect(hunk.lines.count == 5)

        #expect(hunk.lines[0] == DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "line1"))
        #expect(hunk.lines[1] == DiffLine(kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "line2"))
        #expect(hunk.lines[2] == DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "line2 modified"))
        #expect(hunk.lines[3] == DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 3, text: "line3 added"))
        #expect(hunk.lines[4] == DiffLine(kind: .context, oldLineNumber: 3, newLineNumber: 4, text: "line3"))
    }

    @Test func multipleHunksInOneFileAreParsedSeparately() {
        let diff = """
        @@ -1,2 +1,2 @@
        -a
        +A
        @@ -10,2 +10,3 @@
         x
        +y
         z
        """
        let parsed = UnifiedDiffParser.parse(diff)
        #expect(parsed.hunks.count == 2)
        #expect(parsed.hunks[0].oldStart == 1 && parsed.hunks[0].newStart == 1)
        #expect(parsed.hunks[0].lines.count == 2)
        #expect(parsed.hunks[1].oldStart == 10 && parsed.hunks[1].newStart == 10)
        #expect(parsed.hunks[1].lines.count == 3)
    }

    @Test func additionsOnlyHunkForANewFileHasNoOldLineNumbers() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..abc1234
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        """
        let parsed = UnifiedDiffParser.parse(diff)
        #expect(parsed.hunks.count == 1)
        let lines = parsed.hunks[0].lines
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.kind == .added && $0.oldLineNumber == nil })
        #expect(lines.map(\.newLineNumber) == [1, 2])
        #expect(lines.map(\.text) == ["hello", "world"])
    }

    @Test func deletionsOnlyHunkForARemovedFileHasNoNewLineNumbers() {
        let diff = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index abc1234..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -bye
        -cruel world
        """
        let parsed = UnifiedDiffParser.parse(diff)
        #expect(parsed.hunks.count == 1)
        let lines = parsed.hunks[0].lines
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.kind == .removed && $0.newLineNumber == nil })
        #expect(lines.map(\.oldLineNumber) == [1, 2])
    }

    @Test func binaryFileDiffIsDetectedAndNotParsedAsHunks() {
        let diff = """
        diff --git a/image.png b/image.png
        index 1111111..2222222 100644
        Binary files a/image.png and b/image.png differ
        """
        let parsed = UnifiedDiffParser.parse(diff)
        #expect(parsed.isBinary == true)
        #expect(parsed.hunks.isEmpty)
    }

    @Test func noNewlineAtEndOfFileMarkerLinesAreNotTreatedAsContent() {
        let diff = """
        @@ -1,1 +1,1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let parsed = UnifiedDiffParser.parse(diff)
        #expect(parsed.hunks.count == 1)
        #expect(parsed.hunks[0].lines.count == 2)
        #expect(parsed.hunks[0].lines[0].kind == .removed)
        #expect(parsed.hunks[0].lines[1].kind == .added)
    }

    @Test func wholeFileAsAddedProducesOneHunkWithSequentialNewLineNumbers() {
        let parsed = ParsedDiff.wholeFileAsAdded("one\ntwo\nthree")
        #expect(parsed.isBinary == false)
        #expect(parsed.hunks.count == 1)
        let lines = parsed.hunks[0].lines
        #expect(lines.map(\.text) == ["one", "two", "three"])
        #expect(lines.map(\.newLineNumber) == [1, 2, 3])
        #expect(lines.allSatisfy { $0.kind == .added && $0.oldLineNumber == nil })
    }

    @Test func wholeFileAsAddedDropsOnlyTheTrailingNewlineArtifact() {
        let parsed = ParsedDiff.wholeFileAsAdded("one\ntwo\n")
        #expect(parsed.hunks.count == 1)
        #expect(parsed.hunks[0].lines.map(\.text) == ["one", "two"])
    }

    @Test func wholeFileAsAddedOnEmptyContentYieldsNoHunks() {
        let parsed = ParsedDiff.wholeFileAsAdded("")
        #expect(parsed.hunks.isEmpty)
        #expect(parsed.isBinary == false)
    }
}

@Suite("UnifiedDiffParser.classifyLineChanges")
struct GitLineChangeClassificationTests {

    @Test func pureAdditionLinesAreClassifiedAdded() {
        let diff = """
        @@ -1,1 +1,3 @@
         line1
        +line2
        +line3
        """
        let changes = UnifiedDiffParser.classifyLineChanges(in: UnifiedDiffParser.parse(diff))
        #expect(changes == [2: .added, 3: .added])
    }

    @Test func onePairedRemovedAndAddedLineIsClassifiedModified() {
        let diff = """
        @@ -1,3 +1,3 @@
         line1
        -old
        +new
         line3
        """
        let changes = UnifiedDiffParser.classifyLineChanges(in: UnifiedDiffParser.parse(diff))
        #expect(changes == [2: .modified])
    }

    @Test func excessAddedLinesBeyondThePairedCountAreClassifiedAdded() {
        let diff = """
        @@ -1,3 +1,5 @@
         line1
        -old
        +new1
        +new2
        +new3
         line5
        """
        let changes = UnifiedDiffParser.classifyLineChanges(in: UnifiedDiffParser.parse(diff))
        #expect(changes == [2: .modified, 3: .added, 4: .added])
    }

    @Test func excessRemovedLinesInAMixedBlockAreNotSeparatelyMarkedDeleted() {
        let diff = """
        @@ -1,5 +1,3 @@
         line1
        -old1
        -old2
        -old3
        +new
         line5
        """
        let changes = UnifiedDiffParser.classifyLineChanges(in: UnifiedDiffParser.parse(diff))
        #expect(changes == [2: .modified])
    }

    @Test func pureRemovalBetweenTwoKeptLinesMarksTheFollowingLineDeleted() {
        let diff = """
        @@ -1,3 +1,2 @@
         line1
        -removed
         line3
        """
        let changes = UnifiedDiffParser.classifyLineChanges(in: UnifiedDiffParser.parse(diff))
        // "line3" is now new-file line 2 (line1=1, the removed line has no
        // new-file counterpart) — the marker anchors on the next kept line.
        #expect(changes == [2: .deleted])
    }

    @Test func pureRemovalAtTheEndOfAHunkAnchorsOnePastTheLastKeptLine() {
        let diff = """
        @@ -1,2 +1,1 @@
         line1
        -removed
        """
        let changes = UnifiedDiffParser.classifyLineChanges(in: UnifiedDiffParser.parse(diff))
        #expect(changes == [2: .deleted])
    }

    @Test func multipleHunksContributeToOneCombinedResult() {
        let diff = """
        @@ -1,1 +1,2 @@
         line1
        +line2
        @@ -10,1 +11,1 @@
        -old
        +new
        """
        let changes = UnifiedDiffParser.classifyLineChanges(in: UnifiedDiffParser.parse(diff))
        #expect(changes == [2: .added, 11: .modified])
    }

    @Test func wholeFileAsAddedClassifiesEveryLineAdded() {
        let parsed = ParsedDiff.wholeFileAsAdded("one\ntwo\nthree")
        let changes = UnifiedDiffParser.classifyLineChanges(in: parsed)
        #expect(changes == [1: .added, 2: .added, 3: .added])
    }
}

// MARK: - GitService.parseBranches

@Suite("GitService.parseBranches")
struct GitBranchParsingTests {
    @Test func parsesCurrentLocalBranch() {
        let branches = GitService.parseBranches("* main\n")
        #expect(branches == [GitBranch(name: "main", isCurrent: true, isRemote: false)])
    }

    @Test func parsesNonCurrentLocalBranch() {
        let branches = GitService.parseBranches("  develop\n")
        #expect(branches == [GitBranch(name: "develop", isCurrent: false, isRemote: false)])
    }

    @Test func parsesRemoteBranchStrippingRemotesPrefixButKeepingRemoteName() {
        let branches = GitService.parseBranches("  remotes/origin/main\n")
        #expect(branches == [GitBranch(name: "origin/main", isCurrent: false, isRemote: true)])
    }

    @Test func dropsRemoteSymbolicHeadPointer() {
        let branches = GitService.parseBranches("  remotes/origin/HEAD -> origin/main\n")
        #expect(branches.isEmpty)
    }

    @Test func dropsDetachedHeadMarker() {
        let branches = GitService.parseBranches("* (HEAD detached at abc1234)\n")
        #expect(branches.isEmpty)
    }

    @Test func ignoresBlankLines() {
        let branches = GitService.parseBranches("* main\n\n  develop\n")
        #expect(branches.count == 2)
    }

    @Test func parsesFullGitBranchAOutput() {
        let output = """
        * main
          develop
          remotes/origin/HEAD -> origin/main
          remotes/origin/main
          remotes/origin/develop
        """
        let branches = GitService.parseBranches(output)
        #expect(branches == [
            GitBranch(name: "main", isCurrent: true, isRemote: false),
            GitBranch(name: "develop", isCurrent: false, isRemote: false),
            GitBranch(name: "origin/main", isCurrent: false, isRemote: true),
            GitBranch(name: "origin/develop", isCurrent: false, isRemote: true),
        ])
    }
}

// MARK: - GitService.repoFolderName

@Suite("GitService.repoFolderName")
struct RepoFolderNameTests {
    @Test func stripsDotGitSuffixFromHTTPSURL() {
        #expect(GitService.repoFolderName(from: "https://github.com/user/repo.git") == "repo")
    }

    @Test func handlesURLWithNoDotGitSuffix() {
        #expect(GitService.repoFolderName(from: "https://github.com/user/repo") == "repo")
    }

    @Test func handlesTrailingSlash() {
        #expect(GitService.repoFolderName(from: "https://github.com/user/repo/") == "repo")
    }

    @Test func handlesScpStyleSSHURL() {
        #expect(GitService.repoFolderName(from: "git@github.com:user/repo.git") == "repo")
    }

    @Test func handlesScpStyleSSHURLWithNoPathSeparator() {
        #expect(GitService.repoFolderName(from: "git@host:repo.git") == "repo")
    }

    @Test func fallsBackToRepositoryForEmptyInput() {
        #expect(GitService.repoFolderName(from: "   ") == "repository")
    }
}

// MARK: - TerminalSession.nextActiveId

@Suite("TerminalSession.nextActiveId")
struct TerminalSessionNextActiveIdTests {
    private func session(_ title: String) -> TerminalSession {
        TerminalSession(title: title, shell: "/bin/zsh")
    }

    @Test func closingNonActiveSessionLeavesActiveIdUnchanged() {
        let a = session("a"), b = session("b"), c = session("c")
        let result = TerminalSession.nextActiveId(
            afterClosing: b.id, in: [a, b, c], previousActiveId: a.id
        )
        #expect(result == a.id)
    }

    @Test func closingActiveSessionPrefersTheOneNowAtTheSameIndex() {
        // [a, b, c] closing b (index 1) -> c is now at index 1.
        let a = session("a"), b = session("b"), c = session("c")
        let result = TerminalSession.nextActiveId(
            afterClosing: b.id, in: [a, b, c], previousActiveId: b.id
        )
        #expect(result == c.id)
    }

    @Test func closingActiveLastSessionFallsBackToTheNewLastOne() {
        // [a, b, c] closing c (index 2, out of bounds after removal) -> b.
        let a = session("a"), b = session("b"), c = session("c")
        let result = TerminalSession.nextActiveId(
            afterClosing: c.id, in: [a, b, c], previousActiveId: c.id
        )
        #expect(result == b.id)
    }

    @Test func closingTheOnlySessionLeavesNoActiveSession() {
        let a = session("a")
        let result = TerminalSession.nextActiveId(
            afterClosing: a.id, in: [a], previousActiveId: a.id
        )
        #expect(result == nil)
    }

    @Test func closingAnIdNotInTheListLeavesActiveIdUnchanged() {
        let a = session("a"), b = session("b")
        let bogusId = UUID()
        let result = TerminalSession.nextActiveId(
            afterClosing: bogusId, in: [a, b], previousActiveId: a.id
        )
        #expect(result == a.id)
    }

    @Test func previousActiveIdNilStaysNilWhenClosingAnUnrelatedSession() {
        let a = session("a"), b = session("b")
        let result = TerminalSession.nextActiveId(
            afterClosing: a.id, in: [a, b], previousActiveId: nil
        )
        #expect(result == nil)
    }
}

// MARK: - ConflictParser

@Suite("ConflictParser")
struct ConflictParserTests {

    @Test func fileWithNoMarkersHasNoRegions() {
        let text = "line one\nline two\nline three\n"
        #expect(ConflictParser.parse(text).isEmpty)
    }

    @Test func singleRegionExtractsOursAndTheirsContentAndLabels() {
        let text = """
        before
        <<<<<<< HEAD
        ours line A
        ours line B
        =======
        theirs line A
        >>>>>>> feature-branch
        after
        """
        let regions = ConflictParser.parse(text)
        #expect(regions.count == 1)

        let region = regions[0]
        #expect(region.oursLabel == "HEAD")
        #expect(region.theirsLabel == "feature-branch")
        #expect(region.oursText == "ours line A\nours line B")
        #expect(region.theirsText == "theirs line A")
        #expect(region.startLine == 2)
        #expect(region.endLine == 7)
    }

    @Test func regionRangesCoverExactlyTheMarkerAndContentLines() {
        let text = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n"
        let ns = text as NSString
        let region = ConflictParser.parse(text)[0]

        // The whole range spans from the start of "<<<<<<<" through the end
        // of ">>>>>>> other\n" — replacing it removes all three markers.
        #expect(ns.substring(with: region.range) == "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n")
        // The ours/theirs sub-ranges cover only their own content line(s),
        // terminator included (matching `NSString.lineRange(for:)`'s own
        // convention) so a background-tint attribute over the range fills
        // the full row width, not just up to the last visible glyph.
        #expect(ns.substring(with: region.oursRange) == "ours\n")
        #expect(ns.substring(with: region.theirsRange) == "theirs\n")
    }

    @Test func multipleRegionsInOneFileAreEachParsedIndependently() {
        let text = """
        <<<<<<< HEAD
        first ours
        =======
        first theirs
        >>>>>>> branch-a
        middle, unrelated to either conflict
        <<<<<<< HEAD
        second ours
        =======
        second theirs
        >>>>>>> branch-b
        """
        let regions = ConflictParser.parse(text)
        #expect(regions.count == 2)
        #expect(regions[0].oursText == "first ours")
        #expect(regions[0].theirsText == "first theirs")
        #expect(regions[0].theirsLabel == "branch-a")
        #expect(regions[1].oursText == "second ours")
        #expect(regions[1].theirsText == "second theirs")
        #expect(regions[1].theirsLabel == "branch-b")
    }

    @Test func emptyOursOrTheirsSideYieldsEmptyTextAndZeroLengthRange() {
        // "ours" side is empty (separator immediately follows the opening marker).
        let text = "<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> other\n"
        let region = ConflictParser.parse(text)[0]
        #expect(region.oursText == "")
        #expect(region.oursRange.length == 0)
        #expect(region.theirsText == "theirs")
    }

    @Test func unmatchedOpeningMarkerWithNoSeparatorYieldsNoRegion() {
        let text = "<<<<<<< HEAD\nsome text with no closing markers\n"
        #expect(ConflictParser.parse(text).isEmpty)
    }

    @Test func unmatchedSeparatorWithNoClosingMarkerYieldsNoRegion() {
        let text = "<<<<<<< HEAD\nours\n=======\ntheirs, but no closing marker follows\n"
        #expect(ConflictParser.parse(text).isEmpty)
    }

    @Test func resolvedTextForOursTheirsAndBoth() {
        let region = ConflictParser.parse(
            "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n"
        )[0]
        #expect(region.resolvedText(for: .ours) == "ours")
        #expect(region.resolvedText(for: .theirs) == "theirs")
        #expect(region.resolvedText(for: .both) == "ours\ntheirs")
    }

    @Test func resolvedTextForBothOmitsAnEmptySideRatherThanLeavingAStrayNewline() {
        let text = "<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> other\n"
        let region = ConflictParser.parse(text)[0]
        #expect(region.resolvedText(for: .both) == "theirs")
    }

    @Test func compareDiffMarksOursAsRemovedAndTheirsAsAdded() {
        let text = "<<<<<<< HEAD\nours line\n=======\ntheirs line\n>>>>>>> other\n"
        let region = ConflictParser.parse(text)[0]
        let diff = region.compareDiff
        #expect(diff.hunks.count == 1)
        let lines = diff.hunks[0].lines
        #expect(lines.contains(DiffLine(kind: .removed, oldLineNumber: 1, newLineNumber: nil, text: "ours line")))
        #expect(lines.contains(DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 1, text: "theirs line")))
    }
}

// MARK: - GitService.parsePorcelainStatus

@Suite("GitService.parsePorcelainStatus")
struct GitServiceParsePorcelainStatusTests {

    @Test func modifiedUnstagedFileIsClassifiedUnstaged() {
        let result = GitService.parsePorcelainStatus(" M foo.swift\n")
        #expect(result.unstaged.map(\.path) == ["foo.swift"])
        #expect(result.unstaged.map(\.status) == ["M"])
        #expect(result.staged.isEmpty)
        #expect(result.conflicted.isEmpty)
    }

    @Test func modifiedStagedFileIsClassifiedStaged() {
        let result = GitService.parsePorcelainStatus("M  foo.swift\n")
        #expect(result.staged.map(\.path) == ["foo.swift"])
        #expect(result.staged.map(\.status) == ["M"])
        #expect(result.unstaged.isEmpty)
    }

    @Test func untrackedFileIsClassifiedUntracked() {
        let result = GitService.parsePorcelainStatus("?? new.swift\n")
        #expect(result.untracked.map(\.path) == ["new.swift"])
        #expect(result.untracked.map(\.status) == ["??"])
    }

    @Test func bothModifiedConflictIsClassifiedConflictedNotStagedOrUnstaged() {
        let result = GitService.parsePorcelainStatus("UU conflicted.swift\n")
        #expect(result.conflicted.map(\.path) == ["conflicted.swift"])
        #expect(result.conflicted.map(\.status) == ["UU"])
        #expect(result.staged.isEmpty)
        #expect(result.unstaged.isEmpty)
    }

    @Test func everyDocumentedUnmergedCodeIsClassifiedConflicted() {
        // Porcelain v1's full set of unmerged XY combinations.
        let codes = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        for code in codes {
            let result = GitService.parsePorcelainStatus("\(code) file.swift\n")
            #expect(result.conflicted.map(\.status) == [code], "expected \(code) to be conflicted")
            #expect(result.staged.isEmpty, "expected \(code) not to also appear staged")
            #expect(result.unstaged.isEmpty, "expected \(code) not to also appear unstaged")
        }
    }

    @Test func addedFileIsNotMisclassifiedAsConflicted() {
        // "A " (added to index, clean in working tree) must NOT match the
        // "AA" conflict rule — only both sides being "A" counts.
        let result = GitService.parsePorcelainStatus("A  new.swift\n")
        #expect(result.staged.map(\.path) == ["new.swift"])
        #expect(result.staged.map(\.status) == ["A"])
        #expect(result.conflicted.isEmpty)
    }

    @Test func multipleLinesAreEachClassifiedIndependently() {
        let porcelain = "M  staged.swift\n M unstaged.swift\n?? new.swift\nUU conflicted.swift\n"
        let result = GitService.parsePorcelainStatus(porcelain)
        #expect(result.staged.map(\.path) == ["staged.swift"])
        #expect(result.unstaged.map(\.path) == ["unstaged.swift"])
        #expect(result.untracked.map(\.path) == ["new.swift"])
        #expect(result.conflicted.map(\.path) == ["conflicted.swift"])
    }

    @Test func blankLinesAreIgnored() {
        let result = GitService.parsePorcelainStatus("M  foo.swift\n\n")
        #expect(result.staged.count == 1)
    }
}

// MARK: - DebugService.evaluate response parsing (plan.md item 24)

@Suite("DebugService evaluate parsing")
struct DebugServiceEvaluateParsingTests {

    @Test func parsesDAPEvaluateResponseWithAllFields() {
        let json: [String: Any] = ["result": "42", "type": "Int", "variablesReference": 3]
        let result = DebugService.parseDAPEvaluateResponse(json)
        #expect(result.result == "42")
        #expect(result.type == "Int")
        #expect(result.variablesReference == 3)
    }

    @Test func parsesDAPEvaluateResponseWithMissingOptionalFields() {
        let result = DebugService.parseDAPEvaluateResponse(["result": "nil"])
        #expect(result.result == "nil")
        #expect(result.type == nil)
        #expect(result.variablesReference == 0)
    }

    @Test func parsesDAPEvaluateResponseWithNoResultDefaultsToEmptyString() {
        let result = DebugService.parseDAPEvaluateResponse([:])
        #expect(result.result == "")
    }

    @Test func parsesCDPEvaluateResponsePrefersDescriptionOverRawValue() {
        let json: [String: Any] = ["result": ["type": "object", "description": "Array(3)", "value": "ignored"]]
        let result = DebugService.parseCDPEvaluateResponse(json)
        #expect(result.result == "Array(3)")
        #expect(result.type == "object")
    }

    @Test func parsesCDPEvaluateResponseFallsBackToRawValueWhenNoDescription() {
        let json: [String: Any] = ["result": ["type": "number", "value": 42]]
        let result = DebugService.parseCDPEvaluateResponse(json)
        #expect(result.result == "42")
        #expect(result.type == "number")
    }

    @Test func parsesCDPEvaluateResponseWithNeitherDescriptionNorValueAsUndefined() {
        let json: [String: Any] = ["result": ["type": "undefined"]]
        let result = DebugService.parseCDPEvaluateResponse(json)
        #expect(result.result == "undefined")
    }

    @Test func cdpExceptionMessageIsNilWhenThereWasNoException() {
        let json: [String: Any] = ["result": ["type": "number", "value": 1]]
        #expect(DebugService.cdpEvaluateExceptionMessage(json) == nil)
    }

    @Test func cdpExceptionMessagePrefersTheExceptionDescription() {
        let json: [String: Any] = [
            "exceptionDetails": [
                "text": "Uncaught",
                "exception": ["description": "ReferenceError: x is not defined"]
            ]
        ]
        #expect(DebugService.cdpEvaluateExceptionMessage(json) == "ReferenceError: x is not defined")
    }

    @Test func cdpExceptionMessageFallsBackToTextWhenNoExceptionDescription() {
        let json: [String: Any] = ["exceptionDetails": ["text": "Uncaught SyntaxError"]]
        #expect(DebugService.cdpEvaluateExceptionMessage(json) == "Uncaught SyntaxError")
    }
}

// MARK: - WatchExpression list logic (plan.md item 24)

@Suite("WatchExpression")
struct WatchExpressionTests {

    @Test func appendingTrimsWhitespaceAndAddsToTheEnd() {
        let list = WatchExpression.appending("  foo.bar  ", to: [])
        #expect(list.count == 1)
        #expect(list[0].expression == "foo.bar")
    }

    @Test func appendingABlankExpressionIsANoOp() {
        let existing = [WatchExpression(expression: "a")]
        let list = WatchExpression.appending("   ", to: existing)
        #expect(list.count == 1)
        #expect(list[0].expression == "a")
    }

    @Test func removingDropsOnlyTheMatchingExpression() {
        let a = WatchExpression(expression: "a")
        let b = WatchExpression(expression: "b")
        let list = WatchExpression.removing(a.id, from: [a, b])
        #expect(list.map(\.expression) == ["b"])
    }

    @Test func removingAnUnknownIdIsANoOp() {
        let a = WatchExpression(expression: "a")
        let list = WatchExpression.removing(UUID(), from: [a])
        #expect(list.count == 1)
    }

    @Test func applyingSuccessSetsValueAndTypeAndClearsAnyPriorError() {
        var expr = WatchExpression(expression: "x")
        expr.lastError = "stale error"
        let result = DAPEvaluateResult(result: "42", type: "Int", variablesReference: 0)
        let updated = WatchExpression.applying([expr.id: .success(result)], to: [expr])
        #expect(updated[0].lastValue == "42")
        #expect(updated[0].lastType == "Int")
        #expect(updated[0].lastError == nil)
    }

    @Test func applyingFailureSetsErrorAndClearsAnyPriorValue() {
        var expr = WatchExpression(expression: "x")
        expr.lastValue = "stale value"
        expr.lastType  = "String"
        let updated = WatchExpression.applying([expr.id: .failure("out of scope")], to: [expr])
        #expect(updated[0].lastValue == nil)
        #expect(updated[0].lastType == nil)
        #expect(updated[0].lastError == "out of scope")
    }

    @Test func applyingLeavesExpressionsWithNoMatchingResultUntouched() {
        let a = WatchExpression(expression: "a")
        var b = WatchExpression(expression: "b")
        b.lastValue = "5"
        let outcome = WatchEvaluationOutcome.success(DAPEvaluateResult(result: "1", type: nil, variablesReference: 0))
        let updated = WatchExpression.applying([a.id: outcome], to: [a, b])
        #expect(updated.first { $0.expression == "b" }?.lastValue == "5")
    }
}

// MARK: - Hover chain priority (plan.md item 25, "F4")

@Suite("hoverTier")
struct HoverTierTests {
    @Test func diagnosticAlwaysWinsEvenWhilePausedOnAnIdentifier() {
        let tier = hoverTier(hasDiagnosticAtPosition: true, isDebuggerPaused: true, isIdentifierAtPosition: true)
        #expect(tier == .diagnostic)
    }

    @Test func diagnosticWinsOverLSPWhenNotPaused() {
        let tier = hoverTier(hasDiagnosticAtPosition: true, isDebuggerPaused: false, isIdentifierAtPosition: true)
        #expect(tier == .diagnostic)
    }

    @Test func debugValueWinsWhenPausedOnAnIdentifierWithNoDiagnostic() {
        let tier = hoverTier(hasDiagnosticAtPosition: false, isDebuggerPaused: true, isIdentifierAtPosition: true)
        #expect(tier == .debugValue)
    }

    @Test func lspWinsWhenPausedButNotOnAnIdentifier() {
        let tier = hoverTier(hasDiagnosticAtPosition: false, isDebuggerPaused: true, isIdentifierAtPosition: false)
        #expect(tier == .lsp)
    }

    @Test func lspWinsWhenNotPausedEvenOnAnIdentifier() {
        let tier = hoverTier(hasDiagnosticAtPosition: false, isDebuggerPaused: false, isIdentifierAtPosition: true)
        #expect(tier == .lsp)
    }

    @Test func lspWinsWhenNeitherDiagnosticNorPausedNorIdentifier() {
        let tier = hoverTier(hasDiagnosticAtPosition: false, isDebuggerPaused: false, isIdentifierAtPosition: false)
        #expect(tier == .lsp)
    }
}

// MARK: - Markdown preview (plan.md item 26, "G2")

/// `MarkdownRenderer.render`/`blocks(in:)` are the pure seam behind
/// `MarkdownPreviewView` — no SwiftUI involved, so parsing/grouping is
/// covered directly here.
@Suite("MarkdownRenderer")
struct MarkdownRendererTests {
    @Test func headingBecomesItsOwnHeadingBlock() {
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render("# Title"))
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .heading(level: 1))
        #expect(String(blocks[0].text.characters) == "Title")
    }

    @Test func headingLevelIsPreserved() {
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render("### Sub"))
        #expect(blocks[0].kind == .heading(level: 3))
    }

    @Test func plainParagraphBecomesOneBlock() {
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render("Just some plain text."))
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }

    @Test func multiRunParagraphWithInlineEmphasisStaysOneBlock() {
        // "bold"/"and"/"italic" each land in a separate AttributedString run
        // (different inlinePresentationIntent) but share one paragraph
        // identity — this is the exact case `blocks(in:)`'s run-merging
        // exists for for; must not fragment into three paragraph blocks.
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render("A **bold** and *italic* word."))
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
        #expect(String(blocks[0].text.characters) == "A bold and italic word.")
    }

    @Test func fencedCodeBlockIsClassifiedAsCodeBlockWithLanguageHint() {
        let markdown = "```swift\nlet x = 1\n```"
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render(markdown))
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .codeBlock(language: "swift"))
        #expect(String(blocks[0].text.characters).contains("let x = 1"))
    }

    @Test func blockQuoteIsClassifiedAsBlockQuoteNotPlainParagraph() {
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render("> a quote"))
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .blockQuote)
    }

    @Test func unorderedListItemsAreClassifiedAsUnordered() {
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render("- one\n- two"))
        #expect(blocks.count == 2)
        #expect(blocks[0].kind == .listItem(ordinal: 1, ordered: false))
        #expect(blocks[1].kind == .listItem(ordinal: 2, ordered: false))
    }

    @Test func orderedListItemsAreClassifiedAsOrdered() {
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render("1. one\n2. two"))
        #expect(blocks.count == 2)
        #expect(blocks[0].kind == .listItem(ordinal: 1, ordered: true))
        #expect(blocks[1].kind == .listItem(ordinal: 2, ordered: true))
    }

    @Test func distinctConsecutiveParagraphsStaySeparateBlocks() {
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render("First paragraph.\n\nSecond paragraph."))
        #expect(blocks.count == 2)
        #expect(String(blocks[0].text.characters) == "First paragraph.")
        #expect(String(blocks[1].text.characters) == "Second paragraph.")
    }

    @Test func emptyStringProducesNoBlocks() {
        let blocks = MarkdownRenderer.blocks(in: MarkdownRenderer.render(""))
        #expect(blocks.isEmpty)
    }

    @Test func renderNeverThrowsOutwardForArbitraryText() {
        // No `try`/`throws` in `render`'s signature — this just documents
        // that a source string real markdown never produces (an unterminated
        // fence, stray backticks) still yields *a* renderable string rather
        // than crashing.
        let attributed = MarkdownRenderer.render("Some ```unterminated fence and a stray ` backtick")
        #expect(!String(attributed.characters).isEmpty)
    }
}

// MARK: - VS Code theme import (plan.md item 27, "G4")

/// `EditorTheme`'s colors are stored as private hex and only exposed as
/// `NSColor` — these two helpers round-trip through `NSColor`'s own RGB
/// component accessors (safe here since every color is built via
/// `NSColor(red:green:blue:alpha:)`, always RGB-model) so tests can assert
/// on the original hex triples without needing access to the private
/// storage.
private func hexComponents(_ color: NSColor) -> (UInt8, UInt8, UInt8) {
    (
        UInt8((color.redComponent * 255).rounded()),
        UInt8((color.greenComponent * 255).rounded()),
        UInt8((color.blueComponent * 255).rounded())
    )
}

private func components(ofHex hex: UInt32) -> (UInt8, UInt8, UInt8) {
    (UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
}

@Suite("EditorTheme import-merge init")
struct EditorThemeImportMergeTests {
    @Test func overriddenFieldsWinAndUntouchedFieldsFallBackToBase() {
        let theme = EditorTheme(
            id: "merge-test", name: "Merge Test", base: .darcula,
            overrides: [.background: 0x111111, .keyword: 0x222222]
        )
        #expect(hexComponents(theme.background) == components(ofHex: 0x111111))
        #expect(hexComponents(theme.keyword) == components(ofHex: 0x222222))
        // Every field not present in `overrides` falls back to `base`.
        #expect(hexComponents(theme.foreground) == hexComponents(EditorTheme.darcula.foreground))
        #expect(hexComponents(theme.comment) == hexComponents(EditorTheme.darcula.comment))
        #expect(hexComponents(theme.annotation) == hexComponents(EditorTheme.darcula.annotation))
    }

    @Test func emptyOverridesReproducesBaseExactly() {
        let theme = EditorTheme(id: "clone", name: "Clone", base: .githubLight, overrides: [:])
        #expect(hexComponents(theme.background) == hexComponents(EditorTheme.githubLight.background))
        #expect(hexComponents(theme.function) == hexComponents(EditorTheme.githubLight.function))
    }
}

@Suite("VSCodeThemeImporter.stripJSONCArtifacts")
struct VSCodeThemeImporterStripJSONCTests {
    @Test func lineCommentIsRemoved() {
        let cleaned = VSCodeThemeImporter.stripJSONCArtifacts("{\n  // a comment\n  \"a\": 1\n}")
        #expect(!cleaned.contains("//"))
        #expect(cleaned.contains("\"a\": 1"))
    }

    @Test func blockCommentIsRemoved() {
        let cleaned = VSCodeThemeImporter.stripJSONCArtifacts("{ /* block */ \"a\": 1 }")
        #expect(!cleaned.contains("/*"))
        #expect(cleaned.contains("\"a\": 1"))
    }

    @Test func trailingCommaBeforeClosingBraceIsRemoved() {
        let cleaned = VSCodeThemeImporter.stripJSONCArtifacts("{ \"a\": 1, }")
        #expect(cleaned == "{ \"a\": 1 }")
    }

    @Test func trailingCommaBeforeClosingBracketIsRemoved() {
        let cleaned = VSCodeThemeImporter.stripJSONCArtifacts("[1, 2, ]")
        #expect(cleaned == "[1, 2 ]")
    }

    @Test func doubleSlashInsideAStringLiteralIsNotTreatedAsAComment() {
        let cleaned = VSCodeThemeImporter.stripJSONCArtifacts(
            "{ \"url\": \"https://example.com\", \"a\": 1 }"
        )
        #expect(cleaned.contains("https://example.com"))
        #expect(cleaned.contains("\"a\": 1"))
    }
}

@Suite("VSCodeThemeImporter.parse")
struct VSCodeThemeImporterParseTests {

    private static let sampleJSON = """
    {
      "name": "Sample Theme",
      "type": "dark",
      "colors": {
        "editor.background": "#1E1E2E",
        "editor.foreground": "#CDD6F4",
        "editorCursor.foreground": "#F5E0DC",
        "editor.selectionBackground": "#585B70",
        "editorError.foreground": "#F38BA8"
      },
      "tokenColors": [
        { "scope": "comment", "settings": { "foreground": "#6C7086", "fontStyle": "italic" } },
        { "scope": ["string.quoted", "string.template"], "settings": { "foreground": "#A6E3A1" } },
        { "scope": "keyword.control", "settings": { "foreground": "#CBA6F7" } },
        { "scope": "entity.name.function", "settings": { "foreground": "#89B4FA" } },
        { "scope": "entity.name.type.class", "settings": { "foreground": "#F9E2AF" } },
        { "scope": "constant.numeric", "settings": { "foreground": "#FAB387" } }
      ]
    }
    """

    @Test func parsesNameAndTypeCorrectly() throws {
        let theme = try VSCodeThemeImporter.parse(Self.sampleJSON, id: "sample-theme")
        #expect(theme.id == "sample-theme")
        #expect(theme.name == "Sample Theme")
    }

    @Test func mapsUIChromeColors() throws {
        let theme = try VSCodeThemeImporter.parse(Self.sampleJSON, id: "sample-theme")
        #expect(hexComponents(theme.background) == components(ofHex: 0x1E1E2E))
        #expect(hexComponents(theme.foreground) == components(ofHex: 0xCDD6F4))
        #expect(hexComponents(theme.cursor) == components(ofHex: 0xF5E0DC))
        #expect(hexComponents(theme.selection) == components(ofHex: 0x585B70))
        #expect(hexComponents(theme.diagnosticError) == components(ofHex: 0xF38BA8))
    }

    @Test func mapsTokenColorScopesToSyntaxCategories() throws {
        let theme = try VSCodeThemeImporter.parse(Self.sampleJSON, id: "sample-theme")
        #expect(hexComponents(theme.comment) == components(ofHex: 0x6C7086))
        #expect(hexComponents(theme.string) == components(ofHex: 0xA6E3A1))
        #expect(hexComponents(theme.keyword) == components(ofHex: 0xCBA6F7))
        #expect(hexComponents(theme.function) == components(ofHex: 0x89B4FA))
        #expect(hexComponents(theme.type) == components(ofHex: 0xF9E2AF))
        #expect(hexComponents(theme.number) == components(ofHex: 0xFAB387))
    }

    @Test func fieldsMissingFromTheFileFallBackToTheDarkBaseTheme() throws {
        // No "annotation"-mapping scope and no lineHighlight color in the
        // sample — both must fall back to `.darcula` (chosen because
        // `"type": "dark"`), never left undefined.
        let theme = try VSCodeThemeImporter.parse(Self.sampleJSON, id: "sample-theme")
        #expect(hexComponents(theme.annotation) == hexComponents(EditorTheme.darcula.annotation))
        #expect(hexComponents(theme.lineHighlight) == hexComponents(EditorTheme.darcula.lineHighlight))
    }

    @Test func lightTypeFallsBackToGithubLightNotDarcula() throws {
        let json = """
        { "name": "Light Sample", "type": "light", "colors": { "editor.foreground": "#000000" } }
        """
        let theme = try VSCodeThemeImporter.parse(json, id: "light-sample")
        #expect(hexComponents(theme.background) == hexComponents(EditorTheme.githubLight.background))
        #expect(hexComponents(theme.foreground) == components(ofHex: 0x000000))
    }

    @Test func explicitFallbackOverridesTypeBasedDefault() throws {
        let json = """
        { "name": "No Type", "colors": {} }
        """
        let theme = try VSCodeThemeImporter.parse(json, id: "no-type", fallback: .oneDark)
        #expect(hexComponents(theme.background) == hexComponents(EditorTheme.oneDark.background))
    }

    @Test func firstMatchingTokenColorEntryWinsForARepeatedCategory() throws {
        let json = """
        {
          "name": "Order Test",
          "tokenColors": [
            { "scope": "comment.line", "settings": { "foreground": "#111111" } },
            { "scope": "comment.block.documentation", "settings": { "foreground": "#222222" } }
          ]
        }
        """
        let theme = try VSCodeThemeImporter.parse(json, id: "order-test")
        #expect(hexComponents(theme.comment) == components(ofHex: 0x111111))
    }

    @Test func shorthandThreeDigitHexExpandsEachDigit() throws {
        let json = """
        { "name": "Shorthand", "colors": { "editor.foreground": "#abc" } }
        """
        let theme = try VSCodeThemeImporter.parse(json, id: "shorthand")
        #expect(hexComponents(theme.foreground) == components(ofHex: 0xAABBCC))
    }

    @Test func eightDigitHexDropsTheAlphaChannel() throws {
        let json = """
        { "name": "Alpha", "colors": { "editorCursor.foreground": "#11223344" } }
        """
        let theme = try VSCodeThemeImporter.parse(json, id: "alpha")
        #expect(hexComponents(theme.cursor) == components(ofHex: 0x112233))
    }

    @Test func malformedColorValueFallsBackRatherThanBreakingTheParse() throws {
        let json = """
        { "name": "Bad Color", "type": "dark", "colors": { "editor.background": "not-a-color" } }
        """
        let theme = try VSCodeThemeImporter.parse(json, id: "bad-color")
        #expect(hexComponents(theme.background) == hexComponents(EditorTheme.darcula.background))
    }

    @Test func doubleSlashInsideAStringValueSurvivesTheFullParse() throws {
        // Regression guard for `stripJSONCArtifacts`: a URL-bearing string
        // value elsewhere in the file must not be mistaken for a line
        // comment and truncate the rest of the JSON.
        let json = """
        {
          "name": "URL Theme",
          "description": "See https://example.com/docs for more info",
          "type": "dark",
          "colors": { "editor.background": "#0A0A0A" }
        }
        """
        let theme = try VSCodeThemeImporter.parse(json, id: "url-theme")
        #expect(theme.name == "URL Theme")
        #expect(hexComponents(theme.background) == components(ofHex: 0x0A0A0A))
    }

    @Test func trailingCommaJSONCFileStillParses() throws {
        let jsonc = """
        {
          // theme metadata
          "name": "Comment Theme",
          "type": "dark",
          "colors": {
            "editor.background": "#101010",
          },
          "tokenColors": [
            { "scope": "comment", "settings": { "foreground": "#222222" }, },
          ],
        }
        """
        let theme = try VSCodeThemeImporter.parse(jsonc, id: "jsonc-test")
        #expect(theme.name == "Comment Theme")
        #expect(hexComponents(theme.background) == components(ofHex: 0x101010))
        #expect(hexComponents(theme.comment) == components(ofHex: 0x222222))
    }

    @Test func garbageInputThrowsInvalidJSON() {
        #expect(throws: VSCodeThemeImportError.invalidJSON) {
            try VSCodeThemeImporter.parse("not json at all {{{", id: "garbage")
        }
    }

    @Test func nonObjectJSONThrowsInvalidJSON() {
        #expect(throws: VSCodeThemeImportError.invalidJSON) {
            try VSCodeThemeImporter.parse("[1, 2, 3]", id: "array")
        }
    }

    @Test func validJSONWithNoThemeKeysThrowsEmptyTheme() {
        #expect(throws: VSCodeThemeImportError.emptyTheme) {
            try VSCodeThemeImporter.parse("{ \"unrelated\": true }", id: "unrelated")
        }
    }
}

// MARK: - Quick Open (⌘P) ranking

@Suite("Quick Open ranking")
struct QuickOpenRankingTests {
    private let root = URL(fileURLWithPath: "/Users/someone/Sites/shop")

    private func node(_ relative: String) -> FileNode {
        FileNode(url: root.appendingPathComponent(relative), isDirectory: false)
    }

    private func names(_ query: String, _ files: [String]) -> [String] {
        let index = makeQuickOpenIndex(fileTree: files.map(node), workspaceRootURL: root)
        return rankQuickOpenEntries(index, query: query).map(\.relativePath)
    }

    /// The bug: absolute paths share "/Users/…/cartridges/…" so a greedy
    /// subsequence match consumed the query in the prefix and every file
    /// tied. Filename hits must beat directory-only hits.
    @Test func filenameMatchBeatsDirectoryOnlyMatch() {
        let ranked = names("cart", [
            "cartridges/app_shop/cartridge/client/default/js/product/base.js",
            "cartridges/app_shop/cartridge/templates/default/cart/cart.isml",
            "cartridges/app_shop/cartridge/controllers/Cart.js",
            "cartridges/app_shop/cartridge/scripts/helpers/productHelpers.js",
        ])
        #expect(ranked.first == "cartridges/app_shop/cartridge/controllers/Cart.js")
        #expect(ranked.prefix(2).contains("cartridges/app_shop/cartridge/templates/default/cart/cart.isml"))
        // Directory-only hits trail every filename hit; among themselves the
        // shorter name wins the tie.
        #expect(Array(ranked.suffix(2)) == [
            "cartridges/app_shop/cartridge/client/default/js/product/base.js",
            "cartridges/app_shop/cartridge/scripts/helpers/productHelpers.js",
        ])
    }

    @Test func queryOnlyInAbsolutePrefixDoesNotMatch() {
        #expect(names("someone", ["src/app.ts", "README.md"]).isEmpty)
        #expect(names("sites", ["src/app.ts", "README.md"]).isEmpty)
    }

    @Test func exactAndPrefixNameMatchesRankHighest() {
        let ranked = names("helpers", [
            "cartridges/app_shop/cartridge/scripts/helpers/productHelpers.js",
            "test/unit/app_shop/scripts/helpers.js",
            "cartridges/app_shop/cartridge/scripts/helpers/cartHelpers.js",
        ])
        #expect(ranked.first == "test/unit/app_shop/scripts/helpers.js")
    }

    @Test func shorterNameWinsTies() {
        let ranked = names("base", ["src/base.js", "src/basement.js"])
        #expect(ranked == ["src/base.js", "src/basement.js"])
    }

    @Test func slashQueryMatchesAgainstPath() {
        let ranked = names("controllers/cart", [
            "cartridges/app_shop/cartridge/controllers/Cart.js",
            "cartridges/app_shop/cartridge/templates/default/cart/cart.isml",
        ])
        #expect(ranked.first == "cartridges/app_shop/cartridge/controllers/Cart.js")
    }

    @Test func directoryLettersStillReachableWhenNameDoesNotMatch() {
        let ranked = names("shopcart", ["cartridges/app_shop/cartridge/controllers/Cart.js", "README.md"])
        #expect(ranked == ["cartridges/app_shop/cartridge/controllers/Cart.js"])
    }

    @Test func emptyQueryListsEverythingInPathOrder() {
        #expect(names("", ["b.js", "a/c.js", "a.js"]) == ["a.js", "a/c.js", "b.js"])
    }

    @Test func noMatchReturnsNothing() {
        #expect(names("zzz", ["src/app.ts"]).isEmpty)
    }

    /// `FileService.buildFileTree` lists the symlink-resolved root, so tree
    /// URLs live under the real directory while `workspace.rootURL` stays
    /// the symlinked path the user opened. The index must still strip it.
    @Test func indexUsesResolvedRootForSymlinkedWorkspace() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("athena-qo-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try fm.createDirectory(at: real.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        let resolvedFile = real.resolvingSymlinksInPath().appendingPathComponent("src/app.ts")
        let index = makeQuickOpenIndex(
            fileTree: [FileNode(url: resolvedFile, isDirectory: false)],
            workspaceRootURL: link
        )
        #expect(index.first?.relativePath == "src/app.ts")
        #expect(index.first?.relativeDirectory == "src")
        #expect(index.first?.name == "app.ts")
    }

    @Test func prefixBeatsCamelCaseScatterForNames() {
        // Bare fuzzyScore ranks "toString" (t + camel S) above "startsWith"
        // for "st"; completion, command and symbol lists use fuzzyNameScore.
        let starts = fuzzyNameScore(query: "st", target: "startsWith")!
        let toStr = fuzzyNameScore(query: "st", target: "toString")!
        #expect(starts > toStr)
        #expect(fuzzyNameScore(query: "zz", target: "startsWith") == nil)
    }

    @Test func fuzzyScoreStillMatchesAbbreviations() {
        #expect(fuzzyScore(query: "sfcclv", target: "SFCCLogView.swift") != nil)
        #expect(fuzzyScore(query: "xyz", target: "SFCCLogView.swift") == nil)
        #expect(fuzzyScore(query: "", target: "anything") == 0)
    }
}

// MARK: - AppState ⌘P index cache

@Suite("AppState quick-open index cache")
@MainActor
struct QuickOpenIndexCacheTests {
    /// `fileTree`'s `didSet` under `@Observable` must actually fire and the
    /// detached rebuild must land back on the main actor — build-time
    /// success alone doesn't prove either.
    @Test func assigningFileTreeRebuildsCachedIndex() async throws {
        let state = AppState()
        let root = URL(fileURLWithPath: "/Users/someone/Sites/shop")
        state.workspace = WorkspaceModel(rootURL: root)
        state.fileTree = [
            FileNode(url: root.appendingPathComponent("src"), isDirectory: true, children: [
                FileNode(url: root.appendingPathComponent("src/app.ts"), isDirectory: false)
            ]),
            FileNode(url: root.appendingPathComponent("README.md"), isDirectory: false),
        ]

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while state.quickOpenIndexVersion == 0 && clock.now < deadline {
            try await clock.sleep(until: clock.now.advanced(by: .milliseconds(10)))
        }

        #expect(state.quickOpenIndexVersion == 1)
        #expect(state.quickOpenIndex.map(\.relativePath) == ["README.md", "src/app.ts"])

        // Clearing the tree (closeWorkspace) empties the cache too.
        state.fileTree = []
        while state.quickOpenIndexVersion == 1 && clock.now < deadline {
            try await clock.sleep(until: clock.now.advanced(by: .milliseconds(10)))
        }
        #expect(state.quickOpenIndex.isEmpty)
    }
}

// MARK: - SFCC script debugger (ADR 0002)

@Suite("SFCCCartridgeMap")
struct SFCCCartridgeMapTests {
    let root = URL(fileURLWithPath: "/Users/dev/shop")

    @Test func localFileToScriptPath() {
        let map = SFCCCartridgeMap(cartridges: ["app_shop": root.appendingPathComponent("cartridges/app_shop")])
        let file = root.appendingPathComponent("cartridges/app_shop/cartridge/controllers/Cart.js")
        #expect(map.scriptPath(for: file) == "/app_shop/cartridge/controllers/Cart.js")
    }

    @Test func scriptPathWorksWithoutDiscovery() {
        let file = root.appendingPathComponent("cartridges/int_ocapi/cartridge/scripts/services/Foo.js")
        #expect(SFCCCartridgeMap().scriptPath(for: file) == "/int_ocapi/cartridge/scripts/services/Foo.js")
    }

    @Test func cartridgesFolderIsNotMistakenForCartridge() {
        // "cartridges" ≠ "cartridge"; a file directly under cartridges/ isn't in a cartridge.
        #expect(SFCCCartridgeMap().scriptPath(for: root.appendingPathComponent("cartridges/README.md")) == nil)
        #expect(SFCCCartridgeMap().scriptPath(for: root.appendingPathComponent("package.json")) == nil)
    }

    @Test func unknownCartridgeIsRejectedWhenMapIsKnown() {
        let map = SFCCCartridgeMap(cartridges: ["app_shop": root.appendingPathComponent("cartridges/app_shop")])
        let other = root.appendingPathComponent("vendor/app_other/cartridge/controllers/X.js")
        #expect(map.scriptPath(for: other) == nil)
    }

    @Test func scriptPathToLocalFile() {
        let map = SFCCCartridgeMap(cartridges: ["app_shop": root.appendingPathComponent("cartridges/app_shop")])
        #expect(map.localURL(for: "/app_shop/cartridge/controllers/Cart.js")?.path
                == "/Users/dev/shop/cartridges/app_shop/cartridge/controllers/Cart.js")
        #expect(map.localURL(for: "/missing/cartridge/x.js") == nil)
        #expect(map.localURL(for: "/app_shop") == nil)
    }
}

@Suite("DWJSONConfig")
struct DWJSONConfigTests {
    @Test func parsesProphetStyle() {
        let data = Data(#"{"hostname":"dev01-x.demandware.net","username":"u","password":"p","code-version":"v1","cartridgesPath":"cartridges"}"#.utf8)
        let cfg = DWJSONConfig.parse(data)
        #expect(cfg == DWJSONConfig(hostname: "dev01-x.demandware.net", username: "u", password: "p",
                                    codeVersion: "v1", cartridgesPath: "cartridges"))
    }

    @Test func acceptsCamelCaseCodeVersionAndMissingOptionals() {
        let cfg = DWJSONConfig.parse(Data(#"{"hostname":"h","codeVersion":"v2"}"#.utf8))
        #expect(cfg?.codeVersion == "v2")
        #expect(cfg?.username == nil)
    }

    @Test func rejectsMissingHostname() {
        #expect(DWJSONConfig.parse(Data(#"{"username":"u"}"#.utf8)) == nil)
        #expect(DWJSONConfig.parse(Data("not json".utf8)) == nil)
    }
}

@Suite("LaunchConfig.from(json:)")
struct LaunchConfigParsingTests {
    @Test func parsesProphetLaunchEntry() {
        let cfg = LaunchConfig.from(json: [
            "type": "prophet", "request": "launch", "name": "Attach to Sandbox",
            "hostname": "h", "username": "u", "password": "p", "codeversion": "v1"
        ])
        #expect(cfg?.isSFCC == true)
        #expect(cfg?.hostname == "h")
        #expect(cfg?.codeVersion == "v1")
    }

    @Test func requiresTypeNameRequest() {
        #expect(LaunchConfig.from(json: ["type": "node-cdp", "name": "x"]) == nil)
        #expect(LaunchConfig.from(json: ["type": "node-cdp", "name": "x", "request": "launch"])?.isSFCC == false)
    }
}

@Suite("DebugService.resolveSFCCCredentials")
struct SFCCCredentialResolutionTests {
    let dw = DWJSONConfig(hostname: "dw-host", username: "dw-user", password: "dw-pass", codeVersion: "dw-v")
    let conn = SFCCConnection(name: "c", hostname: "conn-host", username: "conn-user", password: "conn-pass", codeVersion: "conn-v")

    @Test func launchConfigWinsThenDWJSONThenConnection() throws {
        let cfg = LaunchConfig(type: "prophet", request: "launch", name: "x", program: "", hostname: "cfg-host")
        let creds = try DebugService.resolveSFCCCredentials(config: cfg, dwJSON: dw, connection: conn)
        #expect(creds == SFCCDebugCredentials(hostname: "cfg-host", username: "dw-user", password: "dw-pass", codeVersion: "dw-v"))

        let fromConn = try DebugService.resolveSFCCCredentials(config: cfg, dwJSON: nil, connection: conn)
        #expect(fromConn.username == "conn-user")
        #expect(fromConn.password == "conn-pass")
    }

    @Test func missingPasswordIsAnError() {
        let cfg = LaunchConfig(type: "prophet", request: "launch", name: "x", program: "", hostname: "h", username: "u")
        #expect(throws: SDAPIError.self) {
            try DebugService.resolveSFCCCredentials(config: cfg, dwJSON: nil, connection: nil)
        }
    }
}

@Suite("SDAPIClient parsing")
struct SDAPIParsingTests {
    @Test func parsesThreadsWithCallStack() throws {
        let data = Data(#"{"_v":"2.0","script_threads":[{"id":3,"status":"halted","call_stack":[{"index":0,"location":{"function_name":"Show","line_number":12,"script_path":"/app_shop/cartridge/controllers/Cart.js"}}]},{"id":4,"status":"running"}]}"#.utf8)
        let threads = try SDAPIClient.parseThreads(data)
        #expect(threads.count == 2)
        #expect(threads[0].status == .halted)
        #expect(threads[0].callStack.first?.location.lineNumber == 12)
        #expect(threads[1].callStack.isEmpty)
        #expect(try SDAPIClient.parseThreads(Data(#"{"_v":"2.0"}"#.utf8)).isEmpty)
    }

    @Test func parsesMembersEvalAndBreakpoints() throws {
        let members = try SDAPIClient.parseMembers(Data(#"{"object_members":[{"name":"cart","parent":"","type":"dw.order.Basket","value":"[Basket]","scope":"local"}],"total":1}"#.utf8))
        #expect(members.first?.type == "dw.order.Basket")
        #expect(try SDAPIClient.parseEvaluate(Data(#"{"expression":"1+1","result":"2"}"#.utf8)) == "2")
        let bps = try SDAPIClient.parseBreakpoints(Data(#"{"breakpoints":[{"id":7,"line_number":12,"script_path":"/a/cartridge/b.js"}]}"#.utf8))
        #expect(bps == [SFCCDebugBreakpoint(id: 7, lineNumber: 12, scriptPath: "/a/cartridge/b.js")])
    }

    @Test func unknownStatusDoesNotFailDecoding() throws {
        let threads = try SDAPIClient.parseThreads(Data(#"{"script_threads":[{"id":1,"status":"weird"}]}"#.utf8))
        #expect(threads.first?.status == .unknown)
    }

    @Test func faultMessageIsExtracted() {
        let data = Data(#"{"fault":{"type":"ClientAccessForbiddenException","message":"nope"}}"#.utf8)
        #expect(SDAPIClient.errorMessage(from: data, fallback: "x") == "nope")
        #expect(SDAPIClient.errorMessage(from: Data(), fallback: "x") == "x")
    }
}

/// A scripted SDAPI sandbox: records every request and answers from a
/// small state machine, so the whole session — client registration,
/// breakpoint translation, halt detection via polling, stepping, teardown —
/// runs for real without a Commerce Cloud instance.
actor FakeSDAPISandbox {
    struct Call: Equatable { let method: String; let path: String; let body: String? }
    private(set) var calls: [Call] = []
    /// Threads reported by GET threads; tests mutate this to simulate the
    /// storefront hitting a breakpoint.
    var threadsJSON = #"{"script_threads":[]}"#

    /// Simulates a slow sandbox handshake so a Stop can land mid-launch.
    var clientCreationDelay: Duration? = nil
    func setClientCreationDelay(_ d: Duration?) { clientCreationDelay = d }

    func setThreads(_ json: String) { threadsJSON = json }

    func handle(_ request: URLRequest) async -> (Data, Int) {
        let path = request.url!.path.replacingOccurrences(of: "/s/-/dw/debugger/v2_0/", with: "")
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        calls.append(Call(method: request.httpMethod ?? "", path: path, body: body))
        if request.httpMethod == "POST", path == "client", let delay = clientCreationDelay {
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now.advanced(by: delay))
        }
        switch (request.httpMethod, path) {
        case ("POST", "breakpoints"):
            return (Data(#"{"breakpoints":[{"id":1,"line_number":12,"script_path":"/app_shop/cartridge/controllers/Cart.js"}]}"#.utf8), 200)
        case ("GET", "threads"):
            return (Data(threadsJSON.utf8), 200)
        case ("GET", "threads/3"):
            return (Data(#"{"id":3,"status":"halted","call_stack":[{"index":0,"location":{"function_name":"Show","line_number":12,"script_path":"/app_shop/cartridge/controllers/Cart.js"}},{"index":1,"location":{"function_name":"","line_number":40,"script_path":"/app_shop/cartridge/scripts/middleware.js"}}]}"#.utf8), 200)
        case ("GET", _) where path.hasSuffix("/variables"):
            return (Data(#"{"object_members":[{"name":"req","type":"Object","value":"[Object]","scope":"local"},{"name":"dw","type":"Object","value":"[dw]","scope":"global"}]}"#.utf8), 200)
        case ("GET", _) where path.hasSuffix("/eval"):
            return (Data(#"{"result":"42"}"#.utf8), 200)
        default:
            return (Data("{}".utf8), 200)
        }
    }
}

@Suite("SFCCDebugSession end to end")
struct SFCCDebugSessionTests {
    let root = URL(fileURLWithPath: "/Users/dev/shop")
    let halted = #"{"script_threads":[{"id":3,"status":"halted","call_stack":[{"index":0,"location":{"function_name":"Show","line_number":12,"script_path":"/app_shop/cartridge/controllers/Cart.js"}}]}]}"#

    /// Collects callbacks synchronously under a lock so the recorded order
    /// is the emission order (hopping through Tasks would reorder them).
    final class Recorder: Sendable {
        private struct Log { var states: [DebugState] = []; var stops: [DebugStop] = []; var output = "" }
        private let log = OSAllocatedUnfairLock(initialState: Log())
        var states: [DebugState] { log.withLock { $0.states } }
        var stops: [DebugStop] { log.withLock { $0.stops } }
        var output: String { log.withLock { $0.output } }
        func state(_ s: DebugState) { log.withLock { $0.states.append(s) } }
        func stop(_ s: DebugStop) { log.withLock { $0.stops.append(s) } }
        func out(_ t: String) { log.withLock { $0.output += t } }
    }

    private func makeSession(sandbox: FakeSDAPISandbox, recorder: Recorder) throws -> SFCCDebugSession {
        let client = try SDAPIClient(
            credentials: SFCCDebugCredentials(hostname: "sandbox.test", username: "u", password: "p", codeVersion: nil),
            transport: { request in await sandbox.handle(request) }
        )
        return SFCCDebugSession(
            client: client,
            cartridges: SFCCCartridgeMap(cartridges: ["app_shop": root.appendingPathComponent("cartridges/app_shop")]),
            onStateChange: { s in recorder.state(s) },
            onOutput: { t in recorder.out(t) },
            onStopped: { s in recorder.stop(s) },
            pollInterval: .milliseconds(20),
            keepAliveInterval: .milliseconds(60)
        )
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await condition() { return }
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(10)))
        }
    }

    @Test func registersClientTranslatesBreakpointsAndDetectsHalt() async throws {
        let sandbox = FakeSDAPISandbox()
        let recorder = Recorder()
        let session = try makeSession(sandbox: sandbox, recorder: recorder)

        try await session.start(breakpointsByFile: [
            root.appendingPathComponent("cartridges/app_shop/cartridge/controllers/Cart.js").path: [12],
            root.appendingPathComponent("package.json").path: [1],   // not in a cartridge → skipped
        ])

        let calls = await sandbox.calls
        #expect(calls.first == FakeSDAPISandbox.Call(method: "POST", path: "client", body: nil))
        let bp = calls.first { $0.path == "breakpoints" && $0.method == "POST" }
        #expect(bp != nil)
        #expect(bp?.body?.contains(#""script_path":"\/app_shop\/cartridge\/controllers\/Cart.js""#) == true
                || bp?.body?.contains(#""script_path":"/app_shop/cartridge/controllers/Cart.js""#) == true)
        #expect(bp?.body?.contains("package.json") == false)
        await waitUntil { recorder.output.contains("Skipping breakpoint") }

        // Nothing halted yet: state is running, no stop reported.
        await waitUntil { recorder.states.contains(.running) }
        #expect(recorder.stops.isEmpty)

        // Storefront request hits the breakpoint.
        await sandbox.setThreads(halted)
        await waitUntil { !recorder.stops.isEmpty }
        let stop = recorder.stops.first
        #expect(stop?.threadId == 3)
        #expect(stop?.line == 12)
        #expect(stop?.filePath == "/Users/dev/shop/cartridges/app_shop/cartridge/controllers/Cart.js")
        #expect(recorder.states.contains(.paused(reason: "breakpoint")))

        // Same halt is not re-reported on every poll.
        try? await ContinuousClock().sleep(until: ContinuousClock().now.advanced(by: .milliseconds(100)))
        #expect(recorder.stops.count == 1)

        // Frames, variables (globals filtered), eval all address thread 3.
        let frames = try await session.stackFrames()
        #expect(frames.map(\.name) == ["Show", "<anonymous>"])
        #expect(frames[0].sourceURL?.path == "/Users/dev/shop/cartridges/app_shop/cartridge/controllers/Cart.js")
        let vars = try await session.variables(frameIndex: 0)
        #expect(vars.map(\.name) == ["req"])
        #expect(try await session.evaluate("6*7", frameIndex: 0).result == "42")

        // Keep-alive fired at least once while paused.
        await waitUntil { await sandbox.calls.contains { $0.path == "threads/reset" } }

        // Step over → POST threads/3/over; resume → POST threads/3/resume.
        try await session.step(.over)
        #expect(await sandbox.calls.contains { $0.method == "POST" && $0.path == "threads/3/over" })
        let stopsBeforeResume = recorder.stops.count
        try await session.resume()
        #expect(await sandbox.calls.contains { $0.method == "POST" && $0.path == "threads/3/resume" })

        // The sandbox still reports thread 3 halted on the same line (a
        // loop re-hitting the breakpoint): that is a new halt and must be
        // reported again, not swallowed as a duplicate of the last one.
        await waitUntil { recorder.stops.count > stopsBeforeResume }
        #expect(recorder.stops.count == stopsBeforeResume + 1)
        #expect(recorder.states.last == .paused(reason: "breakpoint"))

        await session.stop()
        let final = await sandbox.calls
        #expect(final.contains { $0.method == "DELETE" && $0.path == "breakpoints" })
        #expect(final.last == FakeSDAPISandbox.Call(method: "DELETE", path: "client", body: nil))
        #expect(recorder.states.last == .stopped)
    }

    @Test func resumeWithoutHaltedThreadThrows() async throws {
        let session = try makeSession(sandbox: FakeSDAPISandbox(), recorder: Recorder())
        await #expect(throws: SDAPIError.notPaused) { try await session.resume() }
    }

    /// Stop pressed while the sandbox handshake is in flight: `start` must
    /// unwind (no poll loop, client deleted) and the UI must see `.stopped`.
    @Test func stopDuringStartUnwindsCleanly() async throws {
        let sandbox = FakeSDAPISandbox()
        await sandbox.setClientCreationDelay(.milliseconds(300))
        let recorder = Recorder()
        let session = try makeSession(sandbox: sandbox, recorder: recorder)

        let starter = Task { try await session.start(breakpointsByFile: [:]) }
        try? await ContinuousClock().sleep(until: ContinuousClock().now.advanced(by: .milliseconds(80)))
        await session.stop()
        await #expect(throws: CancellationError.self) { try await starter.value }

        let calls = await sandbox.calls
        #expect(calls.contains { $0.method == "DELETE" && $0.path == "client" })
        #expect(!calls.contains { $0.method == "GET" && $0.path == "threads" })
        await waitUntil { recorder.states.contains(.stopped) }
        #expect(!recorder.states.contains(.running))
    }

    @Test func breakpointUpdateReplacesSandboxSet() async throws {
        let sandbox = FakeSDAPISandbox()
        let recorder = Recorder()
        let session = try makeSession(sandbox: sandbox, recorder: recorder)
        try await session.start(breakpointsByFile: [:])
        try await session.updateBreakpoints(byFile: [
            root.appendingPathComponent("cartridges/app_shop/cartridge/controllers/Cart.js").path: [7]
        ])
        let calls = await sandbox.calls
        let lastDelete = calls.lastIndex { $0.method == "DELETE" && $0.path == "breakpoints" }
        let lastPost = calls.lastIndex { $0.method == "POST" && $0.path == "breakpoints" }
        #expect(lastDelete != nil && lastPost != nil && lastDelete! < lastPost!)
        #expect(calls[lastPost!].body?.contains("\"line_number\":7") == true)
        await session.stop()
    }
}

@Suite("SDAPIClient request building")
struct SDAPIRequestBuildingTests {
    @Test func plusInExpressionsIsPercentEncoded() {
        // URLComponents leaves "+" bare and the servlet reads it as a space.
        #expect(SDAPIClient.encodedQuery(["expr": "a + b"]) == "expr=a%20%2B%20b")
        #expect(SDAPIClient.encodedQuery(["count": "10", "start": "0"]) == "count=10&start=0")
        #expect(SDAPIClient.encodedQuery(["object_path": "req.form&x=1"]) == "object_path=req.form%26x%3D1")
    }

    @Test func hostnameForms() {
        #expect(SDAPIClient.baseURL(forHostname: "dev01-x.demandware.net")?.absoluteString
                == "https://dev01-x.demandware.net/s/-/dw/debugger/v2_0/")
        #expect(SDAPIClient.baseURL(forHostname: " https://dev01-x.demandware.net/ ")?.host == "dev01-x.demandware.net")
        #expect(SDAPIClient.baseURL(forHostname: "localhost:1")?.port == 1)
        #expect(SDAPIClient.baseURL(forHostname: "dev 01.demandware.net") == nil)
        #expect(SDAPIClient.baseURL(forHostname: "") == nil)
    }

    @Test func invalidHostnameThrowsInsteadOfCrashing() {
        #expect(throws: SDAPIError.self) {
            _ = try SDAPIClient(credentials: SFCCDebugCredentials(hostname: "bad host", username: "u", password: "p", codeVersion: nil))
        }
    }

    @Test func frameWithoutFunctionNameStillDecodes() throws {
        let threads = try SDAPIClient.parseThreads(Data(#"{"script_threads":[{"id":1,"status":"halted","call_stack":[{"index":0,"location":{"line_number":3,"script_path":"/a/cartridge/b.js"}}]}]}"#.utf8))
        #expect(threads.first?.callStack.first?.location.functionName == "")
    }
}

@Suite("SFCCService.discoverCartridges")
struct SFCCCartridgeDiscoveryTests {
    @Test func findsCartridgesAndSkipsNodeModules() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("athena-cart-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        for dir in ["cartridges/app_shop/cartridge/controllers",
                    "cartridges/int_ocapi/cartridge",
                    "node_modules/some_pkg/cartridge",
                    "cartridges/not_a_cartridge/src"] {
            try fm.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let found = SFCCService.discoverCartridges(under: base)
        #expect(Set(found.keys) == ["app_shop", "int_ocapi"])
        #expect(found["app_shop"]?.lastPathComponent == "app_shop")
    }

    /// Shared cartridges are commonly symlinked into a project.
    @Test func followsSymlinkedCartridges() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("athena-cart-link-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base.appendingPathComponent("shared/plugin_x/cartridge"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("project/cartridges"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: base.appendingPathComponent("project/cartridges/plugin_x"),
                                  withDestinationURL: base.appendingPathComponent("shared/plugin_x"))
        let found = SFCCService.discoverCartridges(under: base.appendingPathComponent("project"))
        #expect(found.keys.contains("plugin_x"))
        // Stored resolved, matching the URLs the file tree produces.
        #expect(found["plugin_x"]?.path == base.appendingPathComponent("shared/plugin_x").resolvingSymlinksInPath().path)
    }
}

// MARK: - Database Feature (engines, export)

@Suite("DBType support")
struct DBTypeSupportTests {
    @Test func onlyEnginesWithDriversAreOffered() {
        #expect(DBType.supportedCases == [.postgresql, .sqlite])
        #expect(DBType.mysql.isSupported == false)
        #expect(DBType.sqlite.isFileBased)
    }

    @Test func legacyConnectionTypesStillDecode() throws {
        let json = Data(#"{"id":"E0000000-0000-0000-0000-000000000001","name":"old","type":"MongoDB","port":27017}"#.utf8)
        let conn = try JSONDecoder().decode(DBConnection.self, from: json)
        #expect(conn.type == .mongodb)
        #expect(conn.type.isSupported == false)
    }
}

@Suite("DBQueryResult helpers")
struct DBQueryResultHelperTests {
    @Test func dedupesColumnNames() {
        #expect(DBQueryResult.uniqueColumnNames(["id", "name", "id", "id"]) == ["id", "name", "id (2)", "id (3)"])
    }

    @Test func detectsDataModifyingStatements() {
        #expect(DBQueryResult.isDataModifying("  insert into t values (1)"))
        #expect(DBQueryResult.isDataModifying("DELETE FROM t"))
        #expect(!DBQueryResult.isDataModifying("CREATE TABLE t (x)"))
        #expect(!DBQueryResult.isDataModifying("SELECT 1"))
    }
}

@Suite("DBExport")
struct DBExportTests {
    let columns = [DBColumn(name: "id", dataTypeName: "int", isPrimaryKey: true),
                   DBColumn(name: "note", dataTypeName: "text", isPrimaryKey: false)]
    let rows = [DBRow(id: 0, values: ["id": .int(1), "note": .text("plain")]),
                DBRow(id: 1, values: ["id": .int(2), "note": .text("has, comma and \"quote\"\nnewline")]),
                DBRow(id: 2, values: ["id": .int(3), "note": .null])]

    @Test func csvQuotesOnlyWhenNeeded() {
        let csv = DBExport.csv(columns: columns, rows: rows)
        #expect(csv == "id,note\r\n1,plain\r\n2,\"has, comma and \"\"quote\"\"\nnewline\"\r\n3,\r\n")
    }

    @Test func jsonIsValidAndTyped() throws {
        let json = DBExport.json(columns: columns, rows: rows)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 3)
        #expect(parsed?[0]["id"] as? Int == 1)
        #expect(parsed?[1]["note"] as? String == "has, comma and \"quote\"\nnewline")
        #expect(parsed?[2]["note"] is NSNull)
    }
}

@Suite("SQLiteService")
struct SQLiteServiceTests {
    private func makeDatabase() throws -> (URL, DBConnection) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("athena-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("shop.sqlite")
        // Create the file via a throwaway connection: SQLite makes the file on open.
        FileManager.default.createFile(atPath: file.path, contents: nil)
        var conn = DBConnection(name: "shop", type: .sqlite)
        conn.database = file.path
        return (dir, conn)
    }

    @Test func browseEditAndQueryRoundTrip() async throws {
        let (dir, conn) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = SQLiteService()
        try await service.connect(conn)

        _ = try await service.runQuery(conn.id, sql: "CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, price REAL)", limit: 10)
        let insert = try await service.runQuery(conn.id, sql: "INSERT INTO products (name, price) VALUES ('Mug', 9.5), ('Tee', 19)", limit: 10)
        #expect(insert.affectedRows == 2)
        #expect(insert.columns.isEmpty)

        let tables = try await service.listTables(conn.id)
        #expect(tables.map(\.name) == ["products"])

        let columns = try await service.columns(conn.id, table: tables[0])
        #expect(columns.map(\.name) == ["id", "name", "price"])
        #expect(columns[0].isPrimaryKey && !columns[1].isPrimaryKey)

        let data = try await service.fetchRows(conn.id, table: tables[0], limit: 200)
        #expect(data.rows.count == 2)
        #expect(data.rows[0].values["name"] == .text("Mug"))
        #expect(data.rows[0].values["price"] == .double(9.5))
        #expect(data.isComplete)

        try await service.updateCell(conn.id, table: tables[0], column: "price",
                                     newValue: .double(11), primaryKeyValues: ["id": .int(1)])
        let select = try await service.runQuery(conn.id, sql: "SELECT name, price FROM products ORDER BY id", limit: 1)
        #expect(select.columns.map(\.name) == ["name", "price"])
        #expect(select.rows.first?.values["price"] == .double(11))
        #expect(select.isTruncated)

        await #expect(throws: (any Error).self) {
            _ = try await service.runQuery(conn.id, sql: "SELEC nonsense", limit: 10)
        }
        await service.disconnect(conn.id)
        #expect(await service.isConnected(conn.id) == false)
    }

    @Test func duplicateColumnNamesTrailingSemicolonAndDDLCount() async throws {
        let (dir, conn) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = SQLiteService()
        try await service.connect(conn)
        _ = try await service.runQuery(conn.id, sql: "CREATE TABLE a (id INTEGER PRIMARY KEY, x TEXT)", limit: 10)
        _ = try await service.runQuery(conn.id, sql: "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER)", limit: 10)
        let insert = try await service.runQuery(conn.id, sql: "INSERT INTO a (x) VALUES ('p'), ('q');", limit: 10)
        #expect(insert.affectedRows == 2)
        _ = try await service.runQuery(conn.id, sql: "INSERT INTO b (a_id) VALUES (1), (2)", limit: 10)

        // DDL after DML must not echo the previous statement's change count.
        let ddl = try await service.runQuery(conn.id, sql: "CREATE INDEX i ON b (a_id)", limit: 10)
        #expect(ddl.affectedRows == nil)

        // Both `id` columns survive, with distinct names, and a trailing ";" is fine.
        let join = try await service.runQuery(conn.id, sql: "SELECT a.id, b.id, a.x FROM a JOIN b ON b.a_id = a.id ORDER BY a.id;", limit: 10)
        #expect(join.columns.map(\.name) == ["id", "id (2)", "x"])
        #expect(join.rows.count == 2)
        #expect(join.rows[1].values["id (2)"] == .int(2))
        #expect(Set(join.columns.map(\.id)).count == 3)

        await #expect(throws: (any Error).self) {
            _ = try await service.runQuery(conn.id, sql: "SELECT 1; SELECT 2", limit: 10)
        }
    }

    @Test func missingFileIsAnError() async {
        var conn = DBConnection(name: "x", type: .sqlite)
        conn.database = "/nonexistent/path/db.sqlite"
        await #expect(throws: (any Error).self) { try await SQLiteService().connect(conn) }
    }
}

// MARK: - Git Feature (stash, sync, file history)

@Suite("GitService.parseStashList")
struct GitStashParsingTests {
    @Test func parsesUnitSeparatedEntries() {
        let output = "stash@{0}\u{1f}On main: wip | with pipe\u{1f}1700000000\nstash@{1}\u{1f}WIP on dev: abc123 msg\u{1f}1690000000\n"
        let stashes = GitService.parseStashList(output)
        #expect(stashes.map(\.index) == [0, 1])
        #expect(stashes[0].message == "On main: wip | with pipe")
        #expect(stashes[0].ref == "stash@{0}")
        #expect(stashes[1].date == Date(timeIntervalSince1970: 1_690_000_000))
        #expect(GitService.parseStashList("").isEmpty)
    }
}

@Suite("GitError messages")
struct GitErrorMessageTests {
    @Test func commandFailureCarriesGitStderr() {
        let error: Error = GitError.commandFailed("fatal: could not read Username for 'https://github.com'\n")
        #expect(error.localizedDescription == "fatal: could not read Username for 'https://github.com'")
    }
}

/// Real git against a throwaway repository — the stash, file-history and
/// push-without-remote paths all shell out, so a parser test alone would
/// prove nothing about the arguments Athena actually passes.
@Suite("GitService integration", .serialized)
struct GitServiceIntegrationTests {
    private func git(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("athena-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["config", "user.email", "t@example.com"], in: dir)
        try git(["config", "user.name", "Test"], in: dir)
        try git(["config", "commit.gpgsign", "false"], in: dir)
        try "a\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: dir)
        try git(["commit", "-q", "-m", "init"], in: dir)
        return dir
    }

    @Test func stashRoundTripAndFileHistory() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = GitService()

        try "a2\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await service.stage(["a.txt"], at: dir)
        try await service.commit(message: "touch a", at: dir)

        // File history: b.txt has one commit, a.txt two.
        #expect(try await service.log(at: dir, limit: 10, path: "b.txt").count == 1)
        #expect(try await service.log(at: dir, limit: 10, path: "a.txt").map(\.message) == ["touch a", "init"])

        try "a3\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await service.stashPush(message: "my work", includeUntracked: false, at: dir)
        var stashes = try await service.stashList(at: dir)
        #expect(stashes.count == 1)
        #expect(stashes[0].message.hasSuffix("my work"))
        #expect(try await service.status(at: dir).isClean)

        try await service.stashApply(stashes[0], pop: true, at: dir)
        #expect(try await service.stashList(at: dir).isEmpty)
        #expect(try await service.status(at: dir).unstaged.map(\.path) == ["a.txt"])

        try await service.stashPush(message: "", includeUntracked: false, at: dir)
        stashes = try await service.stashList(at: dir)
        try await service.stashDrop(stashes[0], at: dir)
        #expect(try await service.stashList(at: dir).isEmpty)
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = String(repeating: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\n", count: 4000) // ~256 KB
        try big.write(to: dir.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try git(["add", "big.txt"], in: dir)
        try git(["commit", "-q", "-m", "big"], in: dir)
        let head = try await GitService().log(at: dir, limit: 1)
        let diff = try await GitService().diff(commit: head[0].hash, at: dir)
        #expect(diff.utf8.count > 200_000)
    }

    @Test func conflictMessageComesFromStdout() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try git(["checkout", "-q", "-b", "other"], in: dir)
        try "other\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "other"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        try "main\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "main"], in: dir)
        try git(["stash", "push", "-q"], in: dir)  // no-op, keeps tree clean
        let service = GitService()
        do {
            try await service.checkout("other", at: dir)
            try "conflict\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try await service.stage(["a.txt"], at: dir)
            try await service.commit(message: "conflicting", at: dir)
            try await service.checkout("main", at: dir)
            // `pull` needs a remote; merging through stash apply reproduces the
            // same stdout-only CONFLICT output path.
            try "wip\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try await service.stashPush(message: "wip", includeUntracked: false, at: dir)
            try "main2\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try await service.stage(["a.txt"], at: dir)
            try await service.commit(message: "main2", at: dir)
            let stashes = try await service.stashList(at: dir)
            try await service.stashApply(stashes[0], pop: true, at: dir)
            Issue.record("stash pop should conflict")
        } catch {
            #expect(error.localizedDescription.contains("CONFLICT"))
        }
    }

    @Test func stashingUntrackedOnlyIsAnError() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "new\n".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: GitError.self) {
            try await GitService().stashPush(message: "", includeUntracked: false, at: dir)
        }
        try await GitService().stashPush(message: "", includeUntracked: true, at: dir)
        #expect(try await GitService().stashList(at: dir).count == 1)
    }

    @Test func pipeInCommitSubjectDoesNotShiftColumns() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "fix: a | b"], in: dir)
        let head = try await GitService().log(at: dir, limit: 1)[0]
        #expect(head.message == "fix: a | b")
        #expect(head.author == "Test")
        #expect(head.date.timeIntervalSince1970 > 1_600_000_000)
    }

    @Test func pushWithoutRemoteFailsWithGitMessage() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try await GitService().push(at: dir)
            Issue.record("push should fail with no remote")
        } catch {
            #expect(error.localizedDescription.contains("origin"))
        }
    }
}

// MARK: - ImportResolver: aliases, workspace packages, node_modules

@Suite("ImportResolver monorepo")
struct ImportResolverMonorepoTests {
    /// A pnpm monorepo: two workspace packages (one with an `exports` map,
    /// one built to dist/), a service with tsconfig `paths`, and node_modules.
    private func makeMonorepo() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("athena-mono-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("pnpm-workspace.yaml", "packages:\n  - 'services/*'\n  # comment\n  - 'packages/*'\n  - '!services/mobile'\n")
        try write("services/common/package.json", #"{"name":"common","main":"./src/index.ts","exports":{".":{"types":"./src/index.ts"},"./server":"./src/server/index.ts","./schemas/*":"./src/schemas/*.ts"}}"#)
        try write("services/common/src/index.ts", "export {}")
        try write("services/common/src/server/index.ts", "export {}")
        try write("services/common/src/queues/index.ts", "export {}")
        try write("services/common/src/util.ts", "export {}")
        try write("services/common/src/schemas/user.ts", "export {}")
        try write("packages/built/package.json", #"{"name":"@kabuto/built","main":"dist/index.js","types":"dist/index.d.ts"}"#)
        try write("packages/built/dist/index.js", "")
        try write("packages/built/dist/index.d.ts", "")
        try write("packages/built/src/index.ts", "export {}")
        try write("services/mobile/package.json", #"{"name":"mobile","main":"index.js"}"#)
        try write("services/mobile/index.js", "")
        try write("services/api/package.json", #"{"name":"api"}"#)
        try write("services/api/tsconfig.json", "{\n  // comment\n  \"compilerOptions\": {\n    \"baseUrl\": \".\",\n    \"paths\": { \"@/*\": [\"./src/*\"], \"@assets/*\": [\"./src/assets/*\"], },\n  },\n}\n")
        try write("services/api/src/app.ts", "export {}")
        try write("services/api/src/lib/db.ts", "export {}")
        try write("services/api/src/assets/logo.svg", "")
        try write("services/api/node_modules/left-pad/package.json", #"{"name":"left-pad","main":"index.js"}"#)
        try write("services/api/node_modules/left-pad/index.js", "")
        try write("node_modules/@scope/pkg/package.json", #"{"name":"@scope/pkg","types":"lib/index.d.ts","main":"lib/index.js"}"#)
        try write("node_modules/@scope/pkg/lib/index.d.ts", "")
        try write("node_modules/@scope/pkg/lib/index.js", "")
        try write("node_modules/@scope/pkg/lib/extra.js", "")
        return root
    }

    private func rel(_ url: URL?, _ root: URL) -> String? {
        url?.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
            .replacingOccurrences(of: root.resolvingSymlinksInPath().path + "/", with: "")
    }

    @Test func resolvesEverythingCmdClickHits() async throws {
        let root = try makeMonorepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = root.appendingPathComponent("services/api/src/app.ts")
        let r = ImportResolver()
        func go(_ spec: String) async -> String? { rel(await r.resolve(spec, from: from, workspaceURL: root), root) }

        #expect(await go("./lib/db") == "services/api/src/lib/db.ts")
        #expect(await go("common") == "services/common/src/index.ts")
        #expect(await go("common/server") == "services/common/src/server/index.ts")      // exports map
        #expect(await go("common/queues") == "services/common/src/queues/index.ts")      // src/ fallback
        #expect(await go("common/util") == "services/common/src/util.ts")
        #expect(await go("common/schemas/user") == "services/common/src/schemas/user.ts") // exports pattern
        #expect(await go("@kabuto/built") == "packages/built/src/index.ts")             // source over dist
        #expect(await go("@/lib/db") == "services/api/src/lib/db.ts")                   // tsconfig paths
        #expect(await go("@assets/logo.svg") == "services/api/src/assets/logo.svg")
        #expect(await go("left-pad") == "services/api/node_modules/left-pad/index.js")  // nearest node_modules
        #expect(await go("@scope/pkg") == "node_modules/@scope/pkg/lib/index.d.ts")     // root node_modules, types
        #expect(await go("@scope/pkg/lib/extra") == "node_modules/@scope/pkg/lib/extra.js")
        #expect(await go("mobile") == nil)                                              // excluded by "!"
        #expect(await go("nope") == nil)
        #expect(await go("node:fs") == nil)
    }

    @Test func helpers() {
        #expect(ImportResolver.packageDir(of: "@scope/pkg/sub/x") == "@scope/pkg")
        #expect(ImportResolver.packageDir(of: "pkg/sub") == "pkg")
        #expect(ImportResolver.substitute("@/lib/db", pattern: "@/*") == "lib/db")
        #expect(ImportResolver.substitute("common", pattern: "common") == "")
        #expect(ImportResolver.substitute("other/x", pattern: "@/*") == nil)
        #expect(ImportResolver.pnpmWorkspaceGlobs("packages:\n  - 'a/*'\n  - \"b\"\n  - '!c'\nother: 1\n") == ["a/*", "b", "!c"])
        let jsonc = ImportResolver.parseJSONC(Data("{ // c\n \"a\": \"http://x/y\", /* b */ \"n\": [1,2,], }".utf8))
        #expect(jsonc?["a"] as? String == "http://x/y")
        #expect((jsonc?["n"] as? [Int]) == [1, 2])
        #expect(ImportResolver.exportsTarget(["./sub/*": ["import": "./src/sub/*.js"]], subpath: "sub/a") == "./src/sub/a.js")
    }
}

// MARK: - Quick Open match cache

@Suite("QuickOpenMatchCache")
@MainActor
struct QuickOpenMatchCacheTests {
    private func index(_ paths: [String]) -> [QuickOpenEntry] {
        let root = URL(fileURLWithPath: "/ws")
        return makeQuickOpenIndex(
            fileTree: paths.map { FileNode(url: root.appendingPathComponent($0), isDirectory: false) },
            workspaceRootURL: root
        )
    }

    /// The palette used to cache matches in `@State` refreshed from
    /// `onChange(of: query)`, so the body rendered the previous query's list.
    /// The cache must answer for the query it is asked about, every time.
    @Test func everyQueryGetsItsOwnResult() {
        let cache = QuickOpenMatchCache()
        let files = index(["-H", "README.md", "src/config/index.ts", "src/index.ts", "web/app/page.tsx"])

        let empty = cache.matches(query: "", index: files, version: 1)
        #expect(empty.count == 5)

        let hits = cache.matches(query: "index.ts", index: files, version: 1)
        // Equal name, equal score: ties fall back to path order.
        #expect(hits.map(\.relativePath) == ["src/config/index.ts", "src/index.ts"])
        #expect(!hits.contains { $0.name == "-H" })

        // Asking again with the earlier query must not return the cached
        // newer list (and vice versa).
        #expect(cache.matches(query: "", index: files, version: 1).count == 5)
        #expect(cache.matches(query: "index.ts", index: files, version: 1).count == 2)
    }

    @Test func aRebuiltIndexInvalidatesTheCache() {
        let cache = QuickOpenMatchCache()
        let before = index(["src/index.ts"])
        #expect(cache.matches(query: "index", index: before, version: 1).count == 1)
        let after = index(["src/index.ts", "api/index.ts"])
        #expect(cache.matches(query: "index", index: after, version: 2).count == 2)
    }
}

// MARK: - Inline blame annotation placement

@Suite("Inline blame label placement")
struct BlameLabelPlacementTests {
    typealias Coordinator = EditorView.Coordinator

    /// A 20pt line whose glyph baseline sits 15pt down, annotated by a
    /// shorter label whose own baseline is 11pt from its top: the label's
    /// top must be 4pt below the line's top so the two baselines meet.
    @Test func labelBaselineMeetsCodeBaseline() {
        let origin = Coordinator.blameLabelOrigin(
            lineUsedRect: CGRect(x: 0, y: 40, width: 300, height: 20),
            lineFragmentRect: CGRect(x: 0, y: 40, width: 600, height: 20),
            glyphBaselineInFragment: 15,
            labelBaselineFromTop: 11,
            textContainerInset: CGSize(width: 5, height: 8)
        )
        // Bound as CGFloat: inside the macro a bare integer expression is
        // evaluated as Int and never compares equal to the CGFloat result.
        let expectedY: CGFloat = 40 + 15 + 8 - 11
        let expectedX: CGFloat = 300 + 5 + 20
        #expect(origin.y == expectedY)
        #expect(origin.x == expectedX)
    }

    /// With a line-height multiple the fragment is taller than the glyphs.
    /// Aligning to the fragment's top (the old behaviour) drifts by the
    /// extra leading; aligning to the baseline does not.
    @Test func lineHeightMultipleDoesNotDrift() {
        let single = Coordinator.blameLabelOrigin(
            lineUsedRect: CGRect(x: 0, y: 0, width: 100, height: 18),
            lineFragmentRect: CGRect(x: 0, y: 0, width: 600, height: 18),
            glyphBaselineInFragment: 14,
            labelBaselineFromTop: 10,
            textContainerInset: .zero
        )
        // Same text at 1.6× line height: the fragment grows and the glyph
        // baseline moves down with it, so the offset from baseline is equal.
        let spaced = Coordinator.blameLabelOrigin(
            lineUsedRect: CGRect(x: 0, y: 0, width: 100, height: 29),
            lineFragmentRect: CGRect(x: 0, y: 0, width: 600, height: 29),
            glyphBaselineInFragment: 25,
            labelBaselineFromTop: 10,
            textContainerInset: .zero
        )
        #expect(single.y == 4)
        #expect(spaced.y == 15)
        let baselineShift: CGFloat = 25 - 14
        #expect(spaced.y - single.y == baselineShift)
    }

    @Test func scrolledLineKeepsTheGapAndBaseline() {
        let origin = Coordinator.blameLabelOrigin(
            lineUsedRect: CGRect(x: 0, y: 1200, width: 412.5, height: 20),
            lineFragmentRect: CGRect(x: 0, y: 1200, width: 600, height: 20),
            glyphBaselineInFragment: 15,
            labelBaselineFromTop: 11,
            textContainerInset: CGSize(width: 5, height: 8),
            gap: 20
        )
        #expect(origin.y == 1212)
        #expect(origin.x == 437.5)
    }
}

// MARK: - Buffer (non-AI) completion

@Suite("BufferCompletionProvider")
struct BufferCompletionProviderTests {
    /// A file where the caret sits right after `cal` on the last line.
    private let source = """
    function calculateTotal(items) {
      const subtotal = items.reduce((sum, item) => sum + item.price, 0)
      return subtotal
    }

    const printed = cal
    """

    private func caret() -> (NSString, Int, NSRange) {
        let text = source as NSString
        let typedRange = text.range(of: "cal", options: .backwards)
        return (text, NSMaxRange(typedRange), typedRange)
    }

    @Test func offersIdentifiersFromTheFileWithNoLanguageServer() {
        let (text, cursor, wordRange) = caret()
        let labels = BufferCompletionProvider.items(in: text, cursor: cursor, wordRange: wordRange).map(\.label)
        #expect(labels.contains("calculateTotal"))
        #expect(labels.contains("subtotal"))
        #expect(labels.contains("items"))
        // The fragment being typed is not a suggestion for itself.
        #expect(!labels.contains("cal"))
        // Too short to be worth a popup row.
        #expect(!labels.contains("0"))
        #expect(!labels.contains("um"))
    }

    @Test func nearerAndMoreFrequentWordsRankFirst() {
        let (text, cursor, wordRange) = caret()
        let words = BufferCompletionProvider.words(in: text, cursor: cursor, wordRange: wordRange)
        guard let printed = words.firstIndex(where: { $0.text == "printed" }),
              let calculate = words.firstIndex(where: { $0.text == "calculateTotal" }) else {
            Issue.record("expected both identifiers"); return
        }
        // `printed` is on the caret's own line; `calculateTotal` is five lines up.
        #expect(printed < calculate)
        #expect(words.first { $0.text == "subtotal" }?.occurrences == 2)
        #expect(words.first { $0.text == "items" }?.occurrences == 2)
    }

    @Test func identifiersCannotStartWithADigit() {
        let text = "let x = 123abc + value_1" as NSString
        let labels = BufferCompletionProvider.items(in: text, cursor: text.length, wordRange: NSRange(location: text.length, length: 0)).map(\.label)
        #expect(labels.contains("abc") == false || labels.contains("123abc") == false)
        #expect(!labels.contains("123abc"))
        #expect(labels.contains("value_1"))
    }

    /// Buffer words must lose a tie to anything semantic: the editor breaks
    /// equal fuzzy scores with `sortText`, and "zz…" sorts last.
    @Test func bufferItemsLoseTiesToSemanticItems() {
        let (text, cursor, wordRange) = caret()
        let buffer = BufferCompletionProvider.items(in: text, cursor: cursor, wordRange: wordRange)
        #expect(buffer.allSatisfy { ($0.sortText ?? "").hasPrefix("zz") })
        let lspSortText = "11"                     // a real server's ordering
        let drizzleFallback = "calculateTotal"     // no sortText → label
        for item in buffer.prefix(5) {
            #expect(lspSortText < (item.sortText ?? ""))
            #expect(drizzleFallback < (item.sortText ?? ""))
        }
        #expect(buffer.allSatisfy { $0.kind == "text" })
    }

    /// Return accepts the popup's selection, so word completion must not
    /// appear while writing prose — it would eat the paragraph break.
    @Test func prosePlainTextAndImagesAreExcluded() {
        #expect(BufferCompletionProvider.isEnabled(for: .markdown) == false)
        #expect(BufferCompletionProvider.isEnabled(for: .plaintext) == false)
        #expect(BufferCompletionProvider.isEnabled(for: .image) == false)
        #expect(BufferCompletionProvider.isEnabled(for: .typescript))
        #expect(BufferCompletionProvider.isEnabled(for: .swift))
        #expect(BufferCompletionProvider.isEnabled(for: .isml))
        #expect(BufferCompletionProvider.isEnabled(for: .json))
        // Untitled buffer: nothing semantic is running, so the buffer is all there is.
        #expect(BufferCompletionProvider.isEnabled(for: nil))
    }

    @Test func emptyAndOversizedBuffersAreSafe() {
        let empty = "" as NSString
        #expect(BufferCompletionProvider.words(in: empty, cursor: 0, wordRange: NSRange(location: 0, length: 0)).isEmpty)
        let huge = String(repeating: "identifier ", count: 200_000) as NSString
        #expect(huge.length > BufferCompletionProvider.maximumScannedCharacters)
        #expect(BufferCompletionProvider.words(in: huge, cursor: 0, wordRange: NSRange(location: 0, length: 0)).isEmpty)
    }
}

// MARK: - When the model is asked instead of the popup

@Suite("GhostTextPolicy")
struct GhostTextPolicyTests {
    private func ask(_ source: String, popupVisible: Bool = false) -> Bool {
        // "|" marks the caret.
        let text = source as NSString
        let caret = text.range(of: "|").location
        let stripped = text.replacingOccurrences(of: "|", with: "") as NSString
        return GhostTextPolicy.shouldRequest(text: stripped, cursor: caret, isPopupVisible: popupVisible)
    }

    @Test func typingAnIdentifierNeverAsksTheModel() {
        #expect(ask("const total = cal|") == false)
        #expect(ask("user.na|") == false)
        #expect(ask("const x = 1\nlet y|") == false)
    }

    @Test func memberAccessIsTheLanguageServersJob() {
        #expect(ask("user.|") == false)
    }

    @Test func popupAlreadyAnsweringSuppressesTheModel() {
        #expect(ask("function run() {\n  |", popupVisible: true) == false)
        #expect(ask("function run() {\n  |", popupVisible: false) == true)
    }

    @Test func blockPositionsAskTheModel() {
        // Fresh body after a signature.
        #expect(ask("function calculateTotal(items) {\n  |") == true)
        // After a comment stating intent.
        #expect(ask("const a = 1\n// sort users by last login\n|") == true)
        // After an assignment.
        #expect(ask("const total = |") == true)
        // Trailing whitespace to the right of the caret is still end-of-line.
        #expect(ask("function run() {\n  |   \n}") == true)
    }

    @Test func midLineAndEmptyDocumentsAreSkipped() {
        // Code to the right: a block suggestion would have to rewrite it.
        #expect(ask("const x = | + total") == false)
        #expect(ask("   \n  |") == false)   // nothing to complete from
        #expect(ask("|const x = 1") == false)
    }

    @Test func onlySubstantialSuggestionsAreShown() {
        #expect(GhostTextPolicy.isSubstantial("  ") == false)
        #expect(GhostTextPolicy.isSubstantial("total") == false)          // popup territory
        #expect(GhostTextPolicy.isSubstantial("items.length") == true)    // 12 chars
        #expect(GhostTextPolicy.isSubstantial("return a\n+ b") == true)   // spans lines
        #expect(GhostTextPolicy.isSubstantial("""
        return items.reduce((sum, item) => sum + item.price, 0)
        """) == true)
    }
}

// MARK: - LSP message framing

@Suite("LSPManager framing")
struct LSPFramingTests {
    /// A pipe hands over whatever has been flushed, not what was asked for.
    /// Reading a body with a single `readData(ofLength:)` truncated every
    /// reply that arrived in more than one chunk.
    @Test func readsABodySplitAcrossWrites() {
        let pipe = Pipe()
        let payload = Data((0..<6000).map { UInt8($0 % 251) })
        DispatchQueue.global().async {
            pipe.fileHandleForWriting.write(payload.prefix(700))
            Thread.sleep(forTimeInterval: 0.05)
            pipe.fileHandleForWriting.write(Data(payload.dropFirst(700)))
        }
        #expect(LSPManager.readExactly(payload.count, from: pipe.fileHandleForReading) == payload)
    }

    @Test func incompleteBodyAtEOFIsRejected() {
        let pipe = Pipe()
        DispatchQueue.global().async {
            pipe.fileHandleForWriting.write(Data([1, 2, 3]))
            try? pipe.fileHandleForWriting.close()
        }
        #expect(LSPManager.readExactly(64, from: pipe.fileHandleForReading) == nil)
    }

    /// What a real `typescript-language-server` sends on startup: a small
    /// `window/logMessage` notification, then the much larger `initialize`
    /// response. The second one is the message that used to go missing.
    @Test func deliversANotificationFollowedByALargeResponse() {
        let pipe = Pipe()
        let notification = Data(#"{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"ready"}}"#.utf8)
        let capabilities = String(repeating: "\"completionProvider\":true,", count: 80)
        let response = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\(capabilities)\"done\":true}}".utf8)

        DispatchQueue.global().async {
            let write = pipe.fileHandleForWriting
            write.write(Data("Content-Length: \(notification.count)\r\n\r\n".utf8))
            write.write(notification)
            write.write(Data("Content-Length: \(response.count)\r\n\r\n".utf8))
            // Split mid-body, exactly the case that used to desynchronise.
            write.write(response.prefix(300))
            Thread.sleep(forTimeInterval: 0.05)
            write.write(Data(response.dropFirst(300)))
            try? write.close()
        }

        var received: [Data] = []
        LSPManager.readFramedMessages(from: pipe.fileHandleForReading) { received.append($0) }

        #expect(received.count == 2)
        #expect(received.first == notification)
        #expect(received.last == response)
        let decoded = received.last.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(decoded?["id"] as? Int == 1)
    }
}

// MARK: - Parameter hints

@Suite("SignatureHelpTrigger")
struct SignatureHelpTriggerTests {
    private func context(_ source: String) -> SignatureHelpTrigger.CallContext? {
        let text = source as NSString
        let caret = text.range(of: "|").location
        let stripped = text.replacingOccurrences(of: "|", with: "") as NSString
        return SignatureHelpTrigger.callContext(text: stripped, cursor: caret)
    }

    @Test func countsArgumentsInTheInnermostCall() {
        #expect(context("format(|")?.argumentIndex == 0)
        #expect(context("format(a, |")?.argumentIndex == 1)
        #expect(context("format(a, b, |")?.argumentIndex == 2)
        // Innermost call wins: the caret is in inner(), not outer().
        let nested = context("outer(a, inner(x, |")
        #expect(nested?.argumentIndex == 1)
        #expect(nested?.openParen == ("outer(a, inner(" as NSString).length - 1)
    }

    @Test func commasInsideStringsAndCommentsAreNotArguments() {
        #expect(context(#"format("a, b", |"#)?.argumentIndex == 1)
        #expect(context(#"format('x, y', 'z, w', |"#)?.argumentIndex == 2)
        #expect(context("format(`a, ${b}, c`, |")?.argumentIndex == 1)
        #expect(context("format(a /* , not an arg */, |")?.argumentIndex == 1)
        #expect(context("format(a, // , ignored\n  |")?.argumentIndex == 1)
        // An escaped quote does not end the string.
        #expect(context(#"format("a\", b", |"#)?.argumentIndex == 1)
    }

    @Test func parensInsideStringsDoNotOpenACall() {
        #expect(context(#"const s = "no (call here" |"#) == nil)
        #expect(context("const x = 1 |") == nil)
        #expect(context("|") == nil)
    }

    @Test func closedCallsAndStatementBoundariesEndTheContext() {
        #expect(context("format(a, b) |") == nil)
        #expect(context("format(a); |") == nil)
        #expect(context("function run() {\n  |") == nil)
        // Still inside after the inner call closes.
        #expect(context("outer(inner(x), |")?.argumentIndex == 1)
    }
}

@Suite("LSPManager.parseSignatureHelp")
struct SignatureHelpParsingTests {
    private func parse(_ json: String) -> SignatureHelp? {
        LSPManager.parseSignatureHelp(from: Data(json.utf8))
    }

    /// Offset labels are the unambiguous form and what Athena asks for.
    @Test func offsetLabelsLocateEachParameter() {
        let help = parse(#"""
        {"result":{"signatures":[{"label":"min(minimum: number, message?: string): ZodString",
        "parameters":[{"label":[4,19]},{"label":[21,37]}]}],"activeSignature":0,"activeParameter":1}}
        """#)
        #expect(help?.label.hasPrefix("min(") == true)
        #expect(help?.parameters.map(\.label) == ["minimum: number", "message?: string"])
        #expect(help?.activeParameter == 1)
        #expect(help?.activeParameterRange == NSRange(location: 21, length: 16))
    }

    /// Text labels: a repeated parameter name must still resolve to the
    /// correct occurrence, so each search starts after the previous match.
    @Test func repeatedTextLabelsResolveInOrder() {
        let help = parse(#"""
        {"result":{"signatures":[{"label":"clamp(value: number, value2: number)",
        "parameters":[{"label":"value: number"},{"label":"value2: number"}]}],"activeParameter":1}}
        """#)
        let second = help?.parameters.last?.labelRange
        #expect(second?.location == 21)
        #expect(help?.activeParameterRange == second)
    }

    @Test func perSignatureActiveParameterWinsAndDocsAreExtracted() {
        let help = parse(#"""
        {"result":{"signatures":[{"label":"fn(a: number)","documentation":{"kind":"markdown","value":"Does a thing"},
        "parameters":[{"label":"a: number","documentation":"the input"}],"activeParameter":0}],"activeParameter":5}}
        """#)
        #expect(help?.activeParameter == 0)
        #expect(help?.documentation == "Does a thing")
        #expect(help?.parameters.first?.documentation == "the input")
    }

    @Test func emptyOrMissingSignaturesYieldNothing() {
        #expect(parse(#"{"result":{"signatures":[]}}"#) == nil)
        #expect(parse(#"{"result":null}"#) == nil)
        #expect(parse("not json") == nil)
    }

    /// Past the last declared parameter (a variadic call) there is nothing
    /// to emphasise, and that must not crash or highlight the wrong span.
    @Test func activeParameterBeyondTheListHighlightsNothing() {
        let help = parse(#"""
        {"result":{"signatures":[{"label":"log(...args: unknown[])","parameters":[{"label":[4,22]}]}],"activeParameter":3}}
        """#)
        #expect(help?.activeParameter == 3)
        #expect(help?.activeParameterRange == nil)
    }

    @Test func localArgumentIndexOverridesTheServers() {
        let help = parse(#"""
        {"result":{"signatures":[{"label":"fn(a, b)","parameters":[{"label":"a"},{"label":"b"}]}],"activeParameter":0}}
        """#)
        #expect(help?.withActiveParameter(1).activeParameterRange == help?.parameters.last?.labelRange)
    }
}

@Suite("SignatureHelpController rendering")
@MainActor
struct SignatureHelpRenderingTests {
    @Test func activeParameterIsEmphasised() {
        let help = SignatureHelp(
            label: "min(minimum: number, message?: string)",
            parameters: [
                SignatureParameter(label: "minimum: number", labelRange: NSRange(location: 4, length: 15), documentation: nil),
                SignatureParameter(label: "message?: string", labelRange: NSRange(location: 21, length: 16), documentation: "shown on failure"),
            ],
            activeParameter: 1,
            documentation: nil
        )
        let rendered = SignatureHelpController.attributedString(for: help, fontSize: 13)
        #expect(rendered.string.hasPrefix("min(minimum: number, message?: string)"))
        // The active parameter's own doc is appended below the signature.
        #expect(rendered.string.contains("shown on failure"))

        let activeFont = rendered.attribute(.font, at: 21, effectiveRange: nil) as? NSFont
        let inactiveFont = rendered.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        #expect(activeFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(inactiveFont?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    @Test func nothingToEmphasiseStillRenders() {
        let help = SignatureHelp(label: "log(...args)", parameters: [], activeParameter: nil, documentation: nil)
        #expect(SignatureHelpController.attributedString(for: help, fontSize: 13).string == "log(...args)")
    }
}

// MARK: - SFCC WebDAV uploader

/// A scripted WebDAV sandbox: records every request and answers from a
/// small policy, so the whole upload protocol runs without a real instance.
actor FakeWebDAV {
    struct Call: Equatable {
        let method: String
        let path: String
        let body: String?
        let auth: String?
    }
    private(set) var calls: [Call] = []
    /// Paths that answer 409 to PUT until their parent has been MKCOL'd.
    var requiresParents = false
    private var createdCollections: Set<String> = []

    func setRequiresParents(_ value: Bool) { requiresParents = value }

    func handle(_ request: URLRequest) -> (Data, Int) {
        let path = request.url!.path
        let method = request.httpMethod ?? ""
        calls.append(Call(
            method: method,
            path: path,
            body: request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            auth: request.value(forHTTPHeaderField: "Authorization")
        ))
        switch method {
        case "MKCOL":
            createdCollections.insert(path)
            return (Data(), 201)
        case "PUT":
            let parent = (path as NSString).deletingLastPathComponent
            if requiresParents && !createdCollections.contains(parent) { return (Data(), 409) }
            return (Data(), 201)
        default:
            return (Data(), 200)
        }
    }

    var methodsAndNames: [String] {
        calls.map { "\($0.method) \(($0.path as NSString).lastPathComponent)" }
    }
}

@Suite("SFCCService uploads")
struct SFCCWebDAVUploadTests {
    private let connection = SFCCConnection(
        name: "dev01", hostname: "dev01.demandware.net", username: "u", password: "p",
        codeVersion: "v42", cartridgesPath: "cartridges", isActive: true
    )

    private func makeWorkspace() throws -> URL {
        let root = try {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("athena-sfcc-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }()
        let controllers = root.appendingPathComponent("cartridges/app_shop/cartridge/controllers")
        try FileManager.default.createDirectory(at: controllers, withIntermediateDirectories: true)
        try "// cart".write(to: controllers.appendingPathComponent("Cart.js"), atomically: true, encoding: .utf8)
        try "<isml/>".write(to: root.appendingPathComponent("cartridges/app_shop/cartridge/home.isml"),
                           atomically: true, encoding: .utf8)
        return root
    }

    @Test func savingAFileUploadsItToTheCodeVersionPath() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sandbox = FakeWebDAV()
        let service = SFCCService(transport: { await sandbox.handle($0) })

        let file = root.appendingPathComponent("cartridges/app_shop/cartridge/controllers/Cart.js")
        _ = try await service.upload(fileURL: file, connection: connection, workspaceURL: root)

        let calls = await sandbox.calls
        #expect(calls.count == 1)
        #expect(calls[0].method == "PUT")
        #expect(calls[0].path == "/on/demandware.servlet/webdav/Sites/Cartridges/v42/app_shop/cartridge/controllers/Cart.js")
        #expect(calls[0].body == "// cart")
        // Basic auth, base64 of "u:p".
        #expect(calls[0].auth == "Basic dTpw")
    }

    /// WebDAV answers 409 when the parent collection is missing, which is
    /// every first file in a new folder. The upload must create the
    /// ancestors and retry rather than reporting a failure.
    @Test func aMissingRemoteFolderIsCreatedThenTheFileRetried() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sandbox = FakeWebDAV()
        await sandbox.setRequiresParents(true)
        let service = SFCCService(transport: { await sandbox.handle($0) })

        let file = root.appendingPathComponent("cartridges/app_shop/cartridge/controllers/Cart.js")
        _ = try await service.upload(fileURL: file, connection: connection, workspaceURL: root)

        let methods = await sandbox.calls.map(\.method)
        #expect(methods.first == "PUT")           // fast path attempted first
        #expect(methods.last == "PUT")            // retried after the MKCOLs
        #expect(methods.filter { $0 == "MKCOL" }.count == 3)   // app_shop, cartridge, controllers
        let mkcols = await sandbox.calls.filter { $0.method == "MKCOL" }.map { ($0.path as NSString).lastPathComponent }
        #expect(mkcols == ["app_shop", "cartridge", "controllers"])
    }

    /// The full re-upload follows Prophet's sequence: stale archive removed,
    /// zip uploaded, remote directory dropped, server-side UNZIP, cleanup.
    @Test func uploadingACartridgeUsesTheZipAndUnzipSequence() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sandbox = FakeWebDAV()
        let service = SFCCService(transport: { await sandbox.handle($0) })

        try await service.uploadCartridge(
            name: "app_shop",
            localDirectory: root.appendingPathComponent("cartridges/app_shop"),
            connection: connection
        )

        #expect(await sandbox.methodsAndNames == [
            "DELETE app_shop_cartridge.zip",
            "PUT app_shop_cartridge.zip",
            "DELETE app_shop",
            "POST app_shop_cartridge.zip",
            "DELETE app_shop_cartridge.zip",
        ])
        let unzip = await sandbox.calls.first { $0.method == "POST" }
        #expect(unzip?.body == "method=UNZIP")
    }

    /// The archive the sandbox expands must contain the cartridge folder
    /// itself, or the files land one level too high.
    @Test func theArchiveIsRootedAtTheCartridgeFolder() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try SFCCService.makeZip(of: root.appendingPathComponent("cartridges/app_shop"), named: "app_shop")
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-Z", "-1", zip.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        try list.run(); list.waitUntilExit()
        let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .components(separatedBy: "\n").filter { !$0.isEmpty }

        #expect(entries.contains("app_shop/cartridge/controllers/Cart.js"))
        #expect(entries.contains("app_shop/cartridge/home.isml"))
        #expect(entries.allSatisfy { $0.hasPrefix("app_shop/") })
    }

    @Test func aRejectedUploadSurfacesTheStatusCode() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SFCCService(transport: { _ in (Data(), 401) })
        let file = root.appendingPathComponent("cartridges/app_shop/cartridge/controllers/Cart.js")
        await #expect(throws: SFCCError.self) {
            _ = try await service.upload(fileURL: file, connection: connection, workspaceURL: root)
        }
    }

    @Test func filesOutsideTheCartridgesRootAreNotUploaded() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let sandbox = FakeWebDAV()
        let service = SFCCService(transport: { await sandbox.handle($0) })
        await #expect(throws: SFCCError.self) {
            _ = try await service.upload(fileURL: root.appendingPathComponent("package.json"),
                                         connection: connection, workspaceURL: root)
        }
        #expect(await sandbox.calls.isEmpty)
    }
}

// MARK: - Upload All Cartridges command

@Suite("SFCC upload command")
struct SFCCUploadCommandTests {
    private var binding: KeyBinding? {
        KeyBinding.vscodeDefaults.first { $0.action == .sfccUploadAllCartridges }
    }

    @Test func isRegisteredAndReachableFromThePalette() {
        #expect(binding != nil)
        #expect(KeyAction.sfccUploadAllCartridges.displayName == "Upload All Cartridges")
        #expect(KeyAction.sfccUploadAllCartridges.category == "SFCC")
        // The command palette ranks on displayName, so the obvious queries
        // must find it.
        for query in ["upload", "cartridges", "upl all", "uac"] {
            #expect(fuzzyNameScore(query: query, target: KeyAction.sfccUploadAllCartridges.displayName) != nil,
                    "'\(query)' should match the command")
        }
    }

    /// It replaces every cartridge on the sandbox, so it must not sit on a
    /// key that can be hit by accident.
    @Test func hasNoDefaultShortcut() {
        #expect(binding?.combo == nil)
    }

    @Test func everyActionHasADefaultBindingEntry() {
        // A case added to KeyAction without a KeyBinding entry would be
        // invisible in both the palette and the keybindings editor.
        let registered = Set(KeyBinding.vscodeDefaults.map(\.action))
        #expect(registered == Set(KeyAction.allCases))
    }
}
