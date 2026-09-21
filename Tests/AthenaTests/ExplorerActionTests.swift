// ExplorerActionTests.swift
// Athena — file tree context-menu actions, driven through AppState.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

// MARK: - Helpers

private func makeWorkspace() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("athena-explorer-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
    try "hello\n".write(to: dir.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    return dir
}

private func runGit(_ args: [String], in dir: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = dir
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try p.run(); p.waitUntilExit()
}

private func node(_ path: String, in tree: [FileNode]) -> FileNode? {
    for candidate in tree {
        if candidate.url.path.hasSuffix("/" + path) { return candidate }
        if let found = node(path, in: candidate.children ?? []) { return found }
    }
    return nil
}

// MARK: - Pure helpers

@Suite("Explorer helpers")
struct ExplorerHelperTests {
    @Test func uniqueDestinationAddsCopySuffixes() {
        let dir = URL(fileURLWithPath: "/w")
        let taken: Set<String> = ["/w/a.txt", "/w/a copy.txt", "/w/Makefile"]
        let exists = { (url: URL) in taken.contains(url.path) }

        #expect(FileService.uniqueDestination(for: URL(fileURLWithPath: "/x/new.txt"), in: dir, exists: exists).path == "/w/new.txt")
        #expect(FileService.uniqueDestination(for: URL(fileURLWithPath: "/w/a.txt"), in: dir, exists: exists).path == "/w/a copy 2.txt")
        #expect(FileService.uniqueDestination(for: URL(fileURLWithPath: "/w/Makefile"), in: dir, exists: exists).path == "/w/Makefile copy")
    }

    @Test func childURLRejectsEscapes() {
        let dir = URL(fileURLWithPath: "/w")
        #expect(AppState.childURL(named: "a/b/c.ts", in: dir)?.path == "/w/a/b/c.ts")
        #expect(AppState.childURL(named: "  x.js ", in: dir)?.path == "/w/x.js")
        #expect(AppState.childURL(named: "", in: dir) == nil)
        #expect(AppState.childURL(named: "/etc/passwd", in: dir) == nil)
        #expect(AppState.childURL(named: "../up.txt", in: dir) == nil)
    }

    @Test func isItemWithinMatchesSelfAndDescendantsOnly() {
        let src = URL(fileURLWithPath: "/w/src")
        #expect(AppState.isItem(URL(fileURLWithPath: "/w/src"), within: src))
        #expect(AppState.isItem(URL(fileURLWithPath: "/w/src/a/b.ts"), within: src))
        #expect(!AppState.isItem(URL(fileURLWithPath: "/w/src2/b.ts"), within: src))
    }
}

// MARK: - AppState flows

@Suite("Explorer actions", .serialized)
@MainActor
struct ExplorerActionTests {
    @Test func createKeepsExpansionAndRefusesOverwrite() async throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        await state.refreshFileTree()

        // Nested path creates intermediate folders, opens the file, and
        // reveals it in the tree.
        await state.createExplorerFile(named: "lib/util.ts", in: dir.appendingPathComponent("src"))
        let created = dir.appendingPathComponent("src/lib/util.ts")
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(state.activeTab?.fileURL?.path == created.path)
        #expect(node("src", in: state.fileTree)?.isExpanded == true)
        #expect(node("src/lib", in: state.fileTree)?.isExpanded == true)

        // An unrelated refresh keeps those folders open.
        await state.refreshFileTree()
        #expect(node("src/lib", in: state.fileTree)?.isExpanded == true)

        // Creating over an existing file must not truncate it.
        await state.createExplorerFile(named: "a.txt", in: dir.appendingPathComponent("src"))
        #expect(try String(contentsOf: dir.appendingPathComponent("src/a.txt"), encoding: .utf8) == "hello\n")
        #expect(state.statusMessage.contains("already exists"))

        await state.createExplorerFolder(named: "assets", in: dir)
        #expect(node("assets", in: state.fileTree)?.isDirectory == true)
    }

    @Test func renameRetargetsOpenTabsAndDuplicateCopies() async throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        let file = dir.appendingPathComponent("src/a.txt")
        await state.openFile(file)

        // Renaming the containing folder moves the open tab along with it.
        await state.renameExplorerItem(dir.appendingPathComponent("src"), to: "lib")
        #expect(state.activeTab?.fileURL?.path == dir.appendingPathComponent("lib/a.txt").path)

        await state.renameExplorerItem(dir.appendingPathComponent("lib/a.txt"), to: "b.md")
        #expect(state.activeTab?.title == "b.md")
        #expect(state.activeTab?.language == .markdown)

        await state.duplicateExplorerItem(dir.appendingPathComponent("lib/b.md"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("lib/b copy.md").path))

        // Renaming onto an existing name is refused, not a silent overwrite.
        await state.renameExplorerItem(dir.appendingPathComponent("lib/b copy.md"), to: "b.md")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("lib/b copy.md").path))
    }

    @Test func compareGitChangesAndPaths() async throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["init", "-q", "-b", "main"], in: dir)
        try runGit(["-c", "user.email=t@example.com", "-c", "user.name=T", "-c", "commit.gpgsign=false",
                    "add", "."], in: dir)
        try runGit(["-c", "user.email=t@example.com", "-c", "user.name=T", "-c", "commit.gpgsign=false",
                    "commit", "-q", "-m", "init"], in: dir)

        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        let a = dir.appendingPathComponent("src/a.txt")
        let b = dir.appendingPathComponent("src/b.txt")
        try "hello\nworld\n".write(to: b, atomically: true, encoding: .utf8)

        #expect(state.workspaceRelativePath(for: a) == "src/a.txt")

        state.selectForCompare(a)
        await state.compareWithSelected(b)
        #expect(state.showDiffViewer)
        #expect(state.diffViewerErrorMessage == nil)
        #expect(!state.diffViewerParsedDiff.hunks.isEmpty)
        state.closeDiffViewer()

        // Open Changes is only offered for files git reports as changed.
        await state.refreshGitStatus()
        #expect(state.gitChange(for: a) == nil)
        try "changed\n".write(to: a, atomically: true, encoding: .utf8)
        await state.refreshGitStatus()
        #expect(state.gitChange(for: a)?.staged == false)
        await state.openChanges(for: a)
        #expect(!state.diffViewerParsedDiff.hunks.isEmpty)

        // Folder history filters the log to the folder.
        await state.showExplorerFileHistory(dir.appendingPathComponent("src"))
        #expect(state.commitHistoryPath == "src")
        #expect(state.commitHistory.map(\.message) == ["init"])
        #expect(state.activeSidebarPanel == .git)

        state.findInFolder(dir.appendingPathComponent("src"))
        #expect(state.searchIncludePrefill == "src")
        #expect(state.activeSidebarPanel == .search)
    }

    @Test func openToSideUsesSecondaryGroup() async throws {
        let dir = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        let file = dir.appendingPathComponent("src/a.txt")

        await state.openFileToSide(file)
        #expect(state.focusedGroup == .secondary)
        #expect(state.secondaryGroup?.tabs.map(\.fileURL) == [file])
        #expect(state.openTabs.isEmpty)

        // Opening a missing file to the side doesn't leave an empty split.
        state.secondaryGroup = nil
        state.focusedGroup = .primary
        await state.openFileToSide(dir.appendingPathComponent("missing.txt"))
        #expect(state.secondaryGroup == nil)
    }
}
