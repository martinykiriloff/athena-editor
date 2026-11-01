// SessionStore.swift
// Athena — persists the hot-exit session snapshot as JSON in Application Support.
// Swift 6, strict concurrency.

import Foundation

actor SessionStore {

    // MARK: - Storage

    /// Readable without hopping onto the actor, so the app-termination path
    /// can write synchronously via `writeSync`.
    nonisolated let fileURL: URL

    /// - Parameter directory: override for tests; defaults to
    ///   `~/Library/Application Support/Athena`.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Athena")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Athena")
        fileURL = base.appendingPathComponent("session.json")
    }

    // MARK: - Read / Write

    func save(_ snapshot: SessionSnapshot) throws {
        try Self.writeSync(snapshot, to: fileURL)
    }

    /// `nil` when there is no file, it is unreadable, or it was written by a
    /// newer format version.
    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              snapshot.version <= SessionSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Synchronous write

    nonisolated static func writeSync(_ snapshot: SessionSnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Disk stamp

    nonisolated static func diskStamp(for url: URL) -> DiskStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return DiskStamp(mtimeMillis: Int64((date.timeIntervalSince1970 * 1000).rounded()), size: size)
    }
}
