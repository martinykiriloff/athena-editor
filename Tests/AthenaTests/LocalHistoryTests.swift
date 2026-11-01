// LocalHistoryTests.swift
// Athena — Local History snapshot dedupe, retention and diff building.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("athena-history-\(UUID().uuidString)")
}

@Suite("Local History")
struct LocalHistoryTests {
    let file = URL(fileURLWithPath: "/tmp/project/src/app.ts")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func dedupesIdenticalContent() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let svc = LocalHistoryService(rootURL: root)
        #expect(try await svc.recordSnapshot(of: file, content: "a", at: t0))
        #expect(try await svc.recordSnapshot(of: file, content: "a", at: t0 + 10) == false)
        #expect(try await svc.recordSnapshot(of: file, content: "b", at: t0 + 20))
        // Going back to "a" is a change relative to the newest snapshot.
        #expect(try await svc.recordSnapshot(of: file, content: "a", at: t0 + 30))
        let snaps = await svc.snapshots(for: file)
        #expect(snaps.count == 3)
        #expect(try await svc.content(of: snaps[0], for: file) == "a")
        #expect(try await svc.content(of: snaps[1], for: file) == "b")
    }

    @Test func capsCountKeepingNewest() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let svc = LocalHistoryService(rootURL: root, maxSnapshotsPerFile: 3)
        for i in 0..<6 { try await svc.recordSnapshot(of: file, content: "v\(i)", at: t0 + Double(i)) }
        let snaps = await svc.snapshots(for: file)
        #expect(snaps.count == 3)
        #expect(try await svc.content(of: snaps[0], for: file) == "v5")
        #expect(try await svc.content(of: snaps[2], for: file) == "v3")
    }

    @Test func dropsSnapshotsOlderThanMaxAge() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let svc = LocalHistoryService(rootURL: root, maxAge: 100)
        try await svc.recordSnapshot(of: file, content: "old", at: t0)
        try await svc.recordSnapshot(of: file, content: "mid", at: t0 + 60)
        try await svc.recordSnapshot(of: file, content: "new", at: t0 + 130)
        let snaps = await svc.snapshots(for: file)
        #expect(snaps.count == 2)
        #expect(try await svc.content(of: snaps[1], for: file) == "mid")
    }

    @Test func filesAreKeyedByPathAndSameTimestampDoesNotCollide() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let svc = LocalHistoryService(rootURL: root)
        let other = URL(fileURLWithPath: "/tmp/project/src/other.ts")
        try await svc.recordSnapshot(of: file, content: "1", at: t0)
        try await svc.recordSnapshot(of: file, content: "2", at: t0)
        try await svc.recordSnapshot(of: other, content: "x", at: t0)
        #expect(await svc.snapshots(for: file).count == 2)
        #expect(await svc.snapshots(for: other).count == 1)
        #expect(LocalHistoryService.key(for: file) != LocalHistoryService.key(for: other))
    }

    @Test func skipsOversizedContent() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let svc = LocalHistoryService(rootURL: root, maxFileBytes: 4)
        #expect(try await svc.recordSnapshot(of: file, content: "12345", at: t0) == false)
        #expect(await svc.snapshots(for: file).isEmpty)
    }

    @Test func lineDiffMarksChanges() {
        let diff = LineDiffBuilder.diff(old: "a\nb\nc\n", new: "a\nB\nc\nd\n")
        let kinds = diff.hunks.flatMap(\.lines).map(\.kind)
        #expect(kinds.filter { $0 == .removed }.count == 1)
        #expect(kinds.filter { $0 == .added }.count == 2)
        #expect(LineDiffBuilder.diff(old: "same\n", new: "same\n").hunks.isEmpty)
    }
}
