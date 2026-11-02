// FrameworkAwarenessTests.swift
// Athena — route discovery, workspace detection, tsconfig aliases, package.json
// lines, Tailwind tokens/completions, refactor grouping, Safe Delete helpers.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("athena-fw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

private func write(_ text: String, to relative: String, in root: URL) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Suite("Next.js routes")
struct RouteDiscoveryTests {
    @Test func appRouterMapping() {
        #expect(RouteDiscovery.appRoute(forRelativePath: "page.tsx")?.0 == "/")
        #expect(RouteDiscovery.appRoute(forRelativePath: "blog/[slug]/page.tsx")?.0 == "/blog/[slug]")
        #expect(RouteDiscovery.appRoute(forRelativePath: "(marketing)/about/page.js")?.0 == "/about")
        #expect(RouteDiscovery.appRoute(forRelativePath: "@modal/login/page.tsx")?.0 == "/login")
        #expect(RouteDiscovery.appRoute(forRelativePath: "api/users/route.ts")?.1 == .api)
        #expect(RouteDiscovery.appRoute(forRelativePath: "layout.tsx") == nil)
        #expect(RouteDiscovery.appRoute(forRelativePath: "feed/(.)photo/page.tsx") == nil)
        #expect(RouteDiscovery.appRoute(forRelativePath: "_private/page.tsx") == nil)
    }

    @Test func pagesRouterMapping() {
        #expect(RouteDiscovery.pagesRoute(forRelativePath: "index.tsx")?.0 == "/")
        #expect(RouteDiscovery.pagesRoute(forRelativePath: "posts/index.tsx")?.0 == "/posts")
        #expect(RouteDiscovery.pagesRoute(forRelativePath: "posts/[id].tsx")?.0 == "/posts/[id]")
        #expect(RouteDiscovery.pagesRoute(forRelativePath: "api/hello.ts")?.1 == .api)
        #expect(RouteDiscovery.pagesRoute(forRelativePath: "_app.tsx") == nil)
        #expect(RouteDiscovery.pagesRoute(forRelativePath: "a.test.tsx") == nil)
    }

    @Test func discoversFromDisk() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", to: "app/page.tsx", in: root)
        try write("", to: "app/dash/page.tsx", in: root)
        try write("", to: "app/dash/layout.tsx", in: root)
        try write("", to: "src/pages/api/x.ts", in: root)
        try write("", to: "app/node_modules/pkg/page.tsx", in: root)
        let routes = RouteDiscovery.discover(in: root).map(\.route)
        #expect(routes == ["/", "/api/x", "/dash"])
    }
}

@Suite("NestJS routes")
struct NestRouteTests {
    @Test func joinsControllerPrefixAndHandlers() {
        let source = """
        @Controller('cats')
        export class CatsController {
          @Get()
          all() {}
          @Post(':id/feed')
          feed() {}
        }
        @Controller({ path: 'dogs' })
        export class DogsController {
          @Delete("/:id")
          rm() {}
        }
        """
        let routes = NestRouteScanner.routes(in: source, fileURL: URL(fileURLWithPath: "/x.controller.ts"))
        #expect(routes.map(\.route) == ["/cats", "/cats/:id/feed", "/dogs/:id"])
        #expect(routes.map { $0.method ?? "" } == ["GET", "POST", "DELETE"])
        #expect(routes.map(\.line) == [3, 5, 10])
    }
}

@Suite("Workspace detection")
struct WorkspaceDetectorTests {
    @Test func pnpmTurboMonorepo() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("packages:\n  - 'apps/*'\n  - 'packages/*'\n", to: "pnpm-workspace.yaml", in: root)
        try write("{}", to: "turbo.json", in: root)
        try write(#"{"name":"web","scripts":{"dev":"next dev","build":"next build"}}"#, to: "apps/web/package.json", in: root)
        try write(#"{"name":"ui"}"#, to: "packages/ui/package.json", in: root)
        let layout = WorkspaceDetector.detect(in: root)
        #expect(layout.manager == .pnpm)
        #expect(layout.orchestrator == .turbo)
        #expect(layout.isMonorepo)
        #expect(layout.packages.map(\.name) == ["web", "ui"])
        #expect(layout.packages.first?.scriptNames == ["build", "dev"])
        #expect(layout.packages.first?.relativePath == "apps/web")
    }

    @Test func plainProjectIsNotMonorepo() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"name":"solo","workspaces":["pkgs/*"]}"#, to: "package.json", in: root)
        try write("", to: "yarn.lock", in: root)
        let layout = WorkspaceDetector.detect(in: root)
        #expect(layout.manager == .yarn)
        #expect(!layout.isMonorepo)
    }
}

@Suite("tsconfig aliases")
struct TSConfigAliasTests {
    private func project() throws -> URL {
        let root = try makeTempDir()
        try write("""
        {
          // comment
          "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["src/*",], "~lib": ["lib/index.ts"] }, },
        }
        """, to: "tsconfig.json", in: root)
        try write("", to: "src/components/Button.tsx", in: root)
        try write("", to: "src/utils.ts", in: root)
        try write("", to: "lib/index.ts", in: root)
        try write("", to: "src/app/main.ts", in: root)
        return root
    }

    @Test func resolvesPathsAndBaseUrl() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = root.appendingPathComponent("src/app/main.ts")
        #expect(ImportResolver.resolveSync("@/components/Button", from: from, workspaceURL: root)?.lastPathComponent == "Button.tsx")
        #expect(ImportResolver.resolveSync("~lib", from: from, workspaceURL: root)?.lastPathComponent == "index.ts")
    }

    @Test func completesAliasRootsAndDirectoryEntries() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("src/app")
        #expect(ImportResolver.aliasCompletions(forPartial: "@", from: dir, workspaceURL: root) == ["@/"])
        let top = ImportResolver.aliasCompletions(forPartial: "@/", from: dir, workspaceURL: root)
        #expect(top.contains("@/components/") && top.contains("@/utils") && top.contains("@/app/"))
        #expect(ImportResolver.aliasCompletions(forPartial: "@/components/B", from: dir, workspaceURL: root) == ["@/components/Button"])
    }
}

@Suite("package.json lines")
struct PackageJSONInspectorTests {
    private let content = """
    {
      "name": "x",
      "dependencies": {
        "react": "^18.2.0",
        "@scope/pkg": "1.0.0"
      },
      "scripts": {
        "build": "tsc"
      }
    }
    """

    @Test func findsDependencyLinesOnly() {
        #expect(PackageJSONInspector.dependency(inContent: content, line: 4)?.name == "react")
        #expect(PackageJSONInspector.dependency(inContent: content, line: 5)?.spec == "1.0.0")
        #expect(PackageJSONInspector.dependency(inContent: content, line: 8) == nil)
        #expect(PackageJSONInspector.dependency(inContent: content, line: 2) == nil)
    }

    @Test func versionComparisonAndNames() {
        #expect(PackageJSONInspector.isNewer("18.3.0", than: "18.2.9"))
        #expect(!PackageJSONInspector.isNewer("18.2.0", than: "18.2.0"))
        #expect(PackageJSONInspector.isNewer("2.0.0", than: "1.99.99-beta.1"))
        #expect(PackageJSONInspector.isValidPackageName("@types/node"))
        #expect(!PackageJSONInspector.isValidPackageName("a; rm -rf /"))
    }

    @Test func installedVersionWalksUpToHoistedModules() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"version":"4.5.6"}"#, to: "node_modules/left-pad/package.json", in: root)
        try write("{}", to: "apps/web/package.json", in: root)
        #expect(PackageJSONInspector.installedVersion(of: "left-pad", from: root.appendingPathComponent("apps/web")) == "4.5.6")
        #expect(PackageJSONInspector.installedVersion(of: "missing-pkg-xyz", from: root.appendingPathComponent("apps/web")) == nil)
    }
}

@Suite("Tailwind")
struct TailwindSupportTests {
    @Test func colourTokens() {
        let text = #"<div class="bg-red-500 text-white/50 border-[#0f0] p-4 bg-[blue] x-bg-red-500">"#
        let tokens = TailwindSupport.colorTokens(in: text)
        #expect(tokens.map(\.hex) == [0xEF4444, 0xFFFFFF, 0x00FF00, 0x0000FF])
        #expect(tokens[1].alpha == 0.5)
    }

    @Test func classContext() {
        #expect(TailwindSupport.classToken(inLinePrefix: #"<div class="flex bg-r"#) == "bg-r")
        #expect(TailwindSupport.classToken(inLinePrefix: #"<div className={"flex "#) == "")
        #expect(TailwindSupport.classToken(inLinePrefix: #"<div class="flex" id="x"#) == nil)
        #expect(TailwindSupport.classToken(inLinePrefix: #"const c = cn("px-2 te"#) == "te")
        #expect(TailwindSupport.classToken(inLinePrefix: #"  @apply font-b"#) == "font-b")
        #expect(TailwindSupport.classToken(inLinePrefix: "let x = 1") == nil)
    }

    @Test func completionReplacesOnlyTheTrailingWord() {
        // Typed "bg-r": the editor replaces "r", so the insert text starts there.
        let items = TailwindSupport.completions(forToken: "bg-r", wordLength: 1)
        let red = items.first { $0.label == "bg-red-500" }
        #expect(red?.insertText == "red-500")
        #expect(red?.detail == "#EF4444")
        let hovered = TailwindSupport.completions(forToken: "md:hover:bg-bl", wordLength: 2)
        #expect(hovered.first { $0.label == "bg-black" }?.insertText == "black")
    }
}

@Suite("Refactor and Safe Delete")
struct RefactorTests {
    private func action(_ kind: String?) -> CodeAction {
        var a = CodeAction(title: kind ?? "none", language: .typescript)
        a.kind = kind
        return a
    }

    @Test func groupsRefactorKinds() {
        let actions = [action("quickfix"), action("refactor.extract.function"), action("refactor.inline.variable"),
                       action("source.organizeImports"), action("refactor"), action("refactor.move.newFile"),
                       action("refactor.rewrite.import.named")]
        let menu = CodeAction.refactorMenu(actions)
        #expect(menu.map(\.group) == [.extract, .inline, .move, .rewrite, .other])
        #expect(menu.flatMap(\.actions).count == 5)
        #expect(CodeAction.refactorMenu(actions, only: .move).flatMap(\.actions).map(\.title) == ["refactor.move.newFile"])
    }

    private func symbol(_ name: String, _ start: Int, _ end: Int, children: [DocumentSymbol]? = nil) -> DocumentSymbol {
        DocumentSymbol(name: name, kind: 12, line: start, character: 10, rangeStartLine: start, rangeEndLine: end, children: children)
    }

    @Test func safeDeleteTargetsInnermostSymbol() {
        let tree = [symbol("Outer", 1, 20, children: [symbol("inner", 5, 9)])]
        #expect(SafeDelete.target(in: tree, line: 6)?.name == "inner")
        #expect(SafeDelete.target(in: tree, line: 12)?.name == "Outer")
        #expect(SafeDelete.target(in: tree, line: 30) == nil)
    }

    @Test func safeDeleteIgnoresOwnLines() {
        let file = URL(fileURLWithPath: "/a.ts"), other = URL(fileURLWithPath: "/b.ts")
        let refs = [DefinitionLocation(fileURL: file, line: 7, character: 1),
                    DefinitionLocation(fileURL: file, line: 30, character: 1),
                    DefinitionLocation(fileURL: other, line: 7, character: 1)]
        let used = SafeDelete.externalUsages(refs, file: file, deletedLines: 5...9)
        #expect(used.map(\.line) == [30, 7])
        #expect(used.last?.fileURL == other)
    }

    @Test func deletionEditRemovesWholeLines() {
        let content = "a\nb\nc\nd"
        let middle = SafeDelete.deletionEdit(lines: 2...3, in: content)
        #expect(applyLSPTextEdits([middle], to: content) == "a\nd")
        let tail = SafeDelete.deletionEdit(lines: 4...4, in: content)
        #expect(applyLSPTextEdits([tail], to: content) == "a\nb\nc\n")
    }
}

@Suite("Search Everywhere")
struct SearchEverywhereScopeTests {
    @Test func prefixesForceScope() {
        #expect(SearchEverywhereScope.parse(">save", tab: .all).scope == .actions)
        #expect(SearchEverywhereScope.parse("# Foo", tab: .files).text == "Foo")
        #expect(SearchEverywhereScope.parse("%todo", tab: .all).scope == .text)
        #expect(SearchEverywhereScope.parse("plain", tab: .symbols).scope == .symbols)
    }
}
