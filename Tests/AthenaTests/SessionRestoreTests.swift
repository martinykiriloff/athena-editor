// SessionRestoreTests.swift
// Athena — hot exit: snapshot encoding, store round trip, restore and disk-change flagging.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("athena-session-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Session snapshot")
struct SessionSnapshotTests {
    @Test func codableRoundTrip() throws {
        var snap = SessionSnapshot()
        snap.workspacePath = "/w"
        snap.primaryTabs = [
            SessionTabState(path: "/w/a.ts", title: "a.ts", cursorLine: 3, cursorColumn: 7,
                            unsavedContent: "let x", diskStamp: DiskStamp(mtimeMillis: 1234, size: 5)),
            SessionTabState(path: nil, title: "Untitled", cursorLine: 1, cursorColumn: 1, unsavedContent: "hi"),
        ]
        snap.primaryActiveIndex = 1
        snap.secondaryTabs = [SessionTabState(path: "/w/a.ts", title: "a.ts", cursorLine: 1, cursorColumn: 1)]
        snap.secondaryFocused = true
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
    }

    @Test func storeSavesLoadsAndRejectsGarbageAndNewerVersions() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        #expect(await store.load() == nil)

        var snap = SessionSnapshot()
        snap.workspacePath = "/w"
        try await store.save(snap)
        #expect(await store.load() == snap)

        try "not json".write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(await store.load() == nil)

        var future = snap
        future.version = SessionSnapshot.currentVersion + 1
        try await store.save(future)
        #expect(await store.load() == nil)

        await store.clear()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}

@Suite("Session restore", .serialized)
@MainActor
struct SessionRestoreTests {
    private func makeFiles() throws -> (dir: URL, a: URL, b: URL) {
        let dir = try makeDir()
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try "disk A\n".write(to: a, atomically: true, encoding: .utf8)
        try "disk B\n".write(to: b, atomically: true, encoding: .utf8)
        return (dir, a, b)
    }

    @Test func snapshotThenRestoreKeepsGroupsActiveCursorsAndUnsaved() async throws {
        let (dir, a, b) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = AppState()
        await first.openFile(a)
        await first.openFile(b)
        first.setCursorPosition(tabId: first.openTabs[1].id, in: .primary, line: 4, column: 2)
        first.updateTabContent(first.openTabs[0].id, content: "edited A")
        first.activateTab(first.openTabs[1].id)
        first.splitEditorRight()          // b.txt copy into secondary, focused
        first.openNewTab(in: .primary)
        first.updateTabContent(first.openTabs[2].id, content: "scratch")
        first.focusedGroup = .secondary

        let snap = first.makeSessionSnapshot()
        #expect(snap.primaryTabs.count == 3)
        #expect(snap.secondaryTabs?.count == 1)
        #expect(snap.primaryTabs[0].unsavedContent == "edited A")
        #expect(snap.primaryTabs[1].unsavedContent == nil)

        let second = AppState()
        await second.applySessionSnapshot(snap)
        #expect(second.openTabs.count == 3)
        #expect(second.openTabs[0].content == "edited A")
        #expect(second.openTabs[0].isDirty)
        #expect(!second.openTabs[0].externallyModified)
        #expect(second.openTabs[1].content == "disk B\n")
        #expect(!second.openTabs[1].isDirty)
        #expect(second.openTabs[1].cursorLine == 4 && second.openTabs[1].cursorColumn == 2)
        #expect(second.openTabs[2].fileURL == nil && second.openTabs[2].content == "scratch")
        #expect(second.activeTabId == second.openTabs[2].id)
        #expect(second.secondaryGroup?.tabs.first?.fileURL == b)
        #expect(second.focusedGroup == .secondary)
    }

    @Test func fileChangedOnDiskIsFlaggedAndNeverOverwritten() async throws {
        let (dir, a, _) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = AppState()
        await first.openFile(a)
        first.updateTabContent(first.openTabs[0].id, content: "my unsaved")
        let snap = first.makeSessionSnapshot()

        // Another program rewrites the file (different size) after the snapshot.
        try "changed elsewhere, longer\n".write(to: a, atomically: true, encoding: .utf8)

        let second = AppState()
        await second.applySessionSnapshot(snap)
        #expect(second.openTabs[0].content == "my unsaved")
        #expect(second.openTabs[0].isDirty)
        #expect(second.openTabs[0].externallyModified)
        #expect(try String(contentsOf: a, encoding: .utf8) == "changed elsewhere, longer\n")
    }

    @Test func deletedFileWithUnsavedEditsIsFlaggedCleanOnesDropped() async throws {
        let (dir, a, b) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = AppState()
        await first.openFile(a)
        await first.openFile(b)
        first.updateTabContent(first.openTabs[0].id, content: "keep me")
        let snap = first.makeSessionSnapshot()
        try FileManager.default.removeItem(at: a)
        try FileManager.default.removeItem(at: b)

        let second = AppState()
        await second.applySessionSnapshot(snap)
        #expect(second.openTabs.count == 1)
        #expect(second.openTabs[0].content == "keep me")
        #expect(second.openTabs[0].externallyModified)
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }
}
