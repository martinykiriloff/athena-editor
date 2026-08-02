import Testing
import Foundation
import AppKit
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
