// FindingYourWayTests.swift
// Athena — recent workspaces, Settings search and first-run tool checks.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

// MARK: - Helpers

private func scratchDefaults() -> UserDefaults {
    let name = "athena-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("athena-recent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Recent workspaces

@Suite("Recent workspaces")
struct RecentWorkspaceTests {
    @Test func newestFirstWithoutDuplicates() {
        let defaults = scratchDefaults()
        AppState.registerRecentWorkspace(URL(fileURLWithPath: "/a"), in: defaults)
        AppState.registerRecentWorkspace(URL(fileURLWithPath: "/b"), in: defaults)
        AppState.registerRecentWorkspace(URL(fileURLWithPath: "/a"), in: defaults)
        #expect(AppState.recentWorkspacePaths(in: defaults) == ["/a", "/b"])
    }

    @Test func capsTheList() {
        let defaults = scratchDefaults()
        for i in 0..<20 { AppState.registerRecentWorkspace(URL(fileURLWithPath: "/w\(i)"), in: defaults) }
        #expect(AppState.recentWorkspacePaths(in: defaults).count == AppState.recentWorkspacesLimit)
        #expect(AppState.recentWorkspacePaths(in: defaults).first == "/w19")
    }

    @Test func removeDropsOnlyThatFolder() {
        let defaults = scratchDefaults()
        AppState.registerRecentWorkspace(URL(fileURLWithPath: "/a"), in: defaults)
        AppState.registerRecentWorkspace(URL(fileURLWithPath: "/b"), in: defaults)
        AppState.removeRecentWorkspace("/a", in: defaults)
        #expect(AppState.recentWorkspacePaths(in: defaults) == ["/b"])
    }

    @Test func seedsFromFoldersInTheSharedRecentList() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let defaults = scratchDefaults()
        defaults.set([file.path, dir.path, "/does/not/exist"].joined(separator: "\n"), forKey: "athenaRecentPaths")

        #expect(AppState.recentWorkspacePaths(in: defaults) == [dir.path])
    }
}

// MARK: - Settings search

@Suite("Settings search")
struct SettingsFilterTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(!SettingsFilter(query: "  ").isActive)
        #expect(SettingsFilter(query: "").matches(["Anything"]))
    }

    @Test func matchesCaseInsensitiveSubstrings() {
        let filter = SettingsFilter(query: "wrap")
        #expect(filter.isActive)
        #expect(filter.matches(["Word Wrap"]))
        #expect(!filter.matches(["Line Numbers"]))
    }

    @Test func everySectionIsFindableByATypicalQuery() {
        func sections(_ q: String) -> [String] {
            SettingsIndex.all.filter { SettingsFilter(query: q).matches([$0.title] + $0.labels) }.map(\.title)
        }
        #expect(sections("font") == ["Font"])
        #expect(sections("tab size") == ["Indentation"])
        #expect(sections("minimap") == ["Minimap"])
        #expect(sections("zzz").isEmpty)
    }
}

// MARK: - Tool checks

@Suite("Tool checks")
struct ToolCheckTests {
    @Test func languageServerNoticesCoverKnownServersOnly() {
        #expect(ToolCheckService.languageServerNotice(for: .typescript)?.id == "lsp.typescript")
        // JS and TS share typescript-language-server, so they share a notice.
        #expect(ToolCheckService.languageServerNotice(for: .javascript)?.id == "lsp.typescript")
        #expect(ToolCheckService.languageServerNotice(for: .go)?.installCommand.contains("gopls") == true)
        #expect(ToolCheckService.languageServerNotice(for: .markdown) == nil)
        #expect(ToolCheckService.languageServerNotice(for: .swift) == nil)
    }

    @Test func missingClaudeBinaryIsReported() async {
        let service = ToolCheckService()
        let notice = await service.claudeNotice(binaryName: "/nonexistent/claude-\(UUID().uuidString)")
        #expect(notice?.id == "claude")
        #expect(notice?.installCommand.isEmpty == false)
    }
}

@Suite("Tool notices", .serialized)
@MainActor
struct ToolNoticeTests {
    @Test func dismissedNoticesStayHidden() {
        let key = AppState.dismissedToolNoticesKey
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let state = AppState()
        let notice = ToolNotice(id: "test.tool", title: "t", detail: "d", installCommand: "c")
        state.showToolNotice(notice)
        state.showToolNotice(notice)
        #expect(state.toolNotices.count == 1)

        state.dismissToolNotice("test.tool")
        #expect(state.toolNotices.isEmpty)
        state.showToolNotice(notice)
        #expect(state.toolNotices.isEmpty)
    }
}
