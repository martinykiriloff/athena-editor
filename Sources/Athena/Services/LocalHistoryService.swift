// LocalHistoryService.swift
// Athena — per-file snapshots taken on save, with dedupe and count/age retention.
// Swift 6, strict concurrency.

import Foundation
import CryptoKit

// MARK: - LocalHistoryError

enum LocalHistoryError: Error {
    case snapshotNotFound
    case unreadable
}

// MARK: - LocalHistoryService

/// Stores snapshots under `<root>/<sha256(path)>/<epochMillis>.snap`.
actor LocalHistoryService {

    let rootURL: URL
    let maxSnapshotsPerFile: Int
    let maxAge: TimeInterval
    let maxFileBytes: Int

    init(
        rootURL: URL = LocalHistoryService.defaultRootURL(),
        maxSnapshotsPerFile: Int = 50,
        maxAge: TimeInterval = 30 * 24 * 3600,
        maxFileBytes: Int = 5_000_000
    ) {
        self.rootURL = rootURL
        self.maxSnapshotsPerFile = maxSnapshotsPerFile
        self.maxAge = maxAge
        self.maxFileBytes = maxFileBytes
    }

    nonisolated static func defaultRootURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Athena/history", isDirectory: true)
    }

    // MARK: - Keys

    nonisolated static func key(for fileURL: URL) -> String {
        let path = fileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func directory(for fileURL: URL) -> URL {
        rootURL.appendingPathComponent(Self.key(for: fileURL), isDirectory: true)
    }

    // MARK: - Recording

    /// Snapshots `content` for `fileURL`. Returns `false` (and writes nothing)
    /// when it is identical to the newest snapshot or exceeds `maxFileBytes`.
    /// Afterwards prunes snapshots older than `maxAge` (relative to `date`)
    /// and any beyond `maxSnapshotsPerFile`, oldest first.
    @discardableResult
    func recordSnapshot(of fileURL: URL, content: String, at date: Date = Date()) throws -> Bool {
        let data = Data(content.utf8)
        guard data.count <= maxFileBytes else { return false }

        let fm = FileManager.default
        let dir = directory(for: fileURL)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let existing = entries(in: dir)
        if let newest = existing.last,
           let newestData = try? Data(contentsOf: dir.appendingPathComponent("\(newest).snap")),
           newestData == data {
            return false
        }

        var millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        if let newest = existing.last, millis <= newest { millis = newest + 1 }
        try data.write(to: dir.appendingPathComponent("\(millis).snap"), options: .atomic)

        prune(dir, now: date)
        return true
    }

    // MARK: - Reading

    /// Snapshots for `fileURL`, newest first.
    func snapshots(for fileURL: URL) -> [LocalHistorySnapshot] {
        let dir = directory(for: fileURL)
        return entries(in: dir).reversed().map { millis in
            let size = (try? dir.appendingPathComponent("\(millis).snap")
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return LocalHistorySnapshot(
                id: String(millis),
                date: Date(timeIntervalSince1970: Double(millis) / 1000),
                byteCount: size
            )
        }
    }

    func content(of snapshot: LocalHistorySnapshot, for fileURL: URL) throws -> String {
        let url = directory(for: fileURL).appendingPathComponent("\(snapshot.id).snap")
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalHistoryError.snapshotNotFound }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw LocalHistoryError.unreadable }
        return text
    }

    // MARK: - Private helpers

    /// Snapshot timestamps in `dir`, ascending.
    private func entries(in dir: URL) -> [Int64] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> Int64? in
            guard name.hasSuffix(".snap") else { return nil }
            return Int64(name.dropLast(5))
        }.sorted()
    }

    private func prune(_ dir: URL, now: Date) {
        let all = entries(in: dir)
        let cutoff = Int64(((now.timeIntervalSince1970 - maxAge) * 1000).rounded())
        var keep = all.filter { $0 >= cutoff }
        if keep.count > maxSnapshotsPerFile { keep = Array(keep.suffix(maxSnapshotsPerFile)) }
        let keepSet = Set(keep)
        for millis in all where !keepSet.contains(millis) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(millis).snap"))
        }
    }
}

// MARK: - LineDiffBuilder

/// Builds a `ParsedDiff` (old to new) from two texts, so history diffs render
/// through the same `DiffHunkView` as Git diffs.
enum LineDiffBuilder {

    static func diff(old: String, new: String, context: Int = 3) -> ParsedDiff {
        let oldLines = split(old), newLines = split(new)
        let change = newLines.difference(from: oldLines)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in change {
            switch c {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var lines: [DiffLine] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                lines.append(DiffLine(kind: .removed, oldLineNumber: i + 1, newLineNumber: nil, text: oldLines[i]))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                lines.append(DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: j + 1, text: newLines[j]))
                j += 1
            } else {
                lines.append(DiffLine(kind: .context, oldLineNumber: i + 1, newLineNumber: j + 1, text: newLines[j]))
                i += 1; j += 1
            }
        }

        // Expand each changed line by `context` and merge overlapping ranges.
        var ranges: [ClosedRange<Int>] = []
        for (idx, line) in lines.enumerated() where line.kind != .context {
            let r = max(0, idx - context)...min(lines.count - 1, idx + context)
            if let last = ranges.last, r.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                ranges.append(r)
            }
        }

        let hunks = ranges.map { r -> DiffHunk in
            let slice = Array(lines[r])
            let oldNums = slice.compactMap(\.oldLineNumber), newNums = slice.compactMap(\.newLineNumber)
            let oldStart = oldNums.first ?? 0, newStart = newNums.first ?? 0
            return DiffHunk(
                header: "@@ -\(oldStart),\(oldNums.count) +\(newStart),\(newNums.count) @@",
                oldStart: oldStart, oldCount: oldNums.count,
                newStart: newStart, newCount: newNums.count,
                lines: slice
            )
        }
        return ParsedDiff(hunks: hunks, isBinary: false)
    }

    private static func split(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
