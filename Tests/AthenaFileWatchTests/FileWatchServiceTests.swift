// FileWatchServiceTests.swift
// Athena — FileWatchService's DispatchSource/kqueue integration tests, in
// their own test target/process.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

// MARK: - FileWatchService
//
// Split into its own test target (plan.md item 6's "Flakiness investigation"
// follow-up) rather than living in `AthenaTests`: these tests spin up a real
// `DispatchSourceFileSystemObject` and wait on real kqueue-delivered events.
// Sharing a process with the other ~200 tests in `AthenaTests` was enough
// concurrent-Task contention to occasionally blow past even a 10s timeout —
// confirmed 100% reliable in isolation (`swift test --filter
// FileWatchServiceTests`) every time this was checked, so the flake was
// process-contention, not a logic bug. Running this suite as its own SwiftPM
// test target gives it its own process with no other tests competing for the
// same executor, removing the contention at its source instead of chasing
// ever-larger timeouts as the main suite keeps growing.
@Suite("FileWatchService", .serialized)
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
    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
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
