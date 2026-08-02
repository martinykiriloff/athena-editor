// SFCCWatchService.swift
// Athena — recursive FSEvents watch over the SFCC cartridges root, feeding auto-upload.
// Swift 6, strict concurrency.

import Foundation
import CoreServices

// MARK: - SFCCWatchService

/// Streams the URLs of files created/modified/renamed/removed anywhere under
/// the cartridges root. `FileWatchService` deliberately watches only open
/// files plus the workspace root (a handful of kqueue descriptors); auto-
/// upload needs the *whole* cartridge tree — compiled static assets, git
/// checkouts, files never opened in a tab — which is exactly what FSEvents'
/// recursive stream provides without one descriptor per directory.
actor SFCCWatchService {

    // MARK: Forwarder

    /// Handed to the C callback through the stream context's `info` pointer.
    /// Immutable and `Sendable` (`AsyncStream.Continuation` is), so the
    /// callback can yield from FSEvents' dispatch queue without touching the
    /// actor. The actor keeps a strong reference for the watch's lifetime;
    /// `info` itself is unretained.
    private final class Forwarder: Sendable {
        let continuation: AsyncStream<[URL]>.Continuation
        init(continuation: AsyncStream<[URL]>.Continuation) { self.continuation = continuation }
    }

    // MARK: State

    private var stream: FSEventStreamRef?
    private var forwarder: Forwarder?

    // MARK: - Public API

    /// Starts watching `root` recursively and returns batches of changed file
    /// URLs. Replaces any existing watch (whose stream finishes). Consumers
    /// decide upload-vs-delete by checking existence at event time — FSEvents
    /// coalesces (a create + delete inside one latency window arrives with
    /// both flag bits set), so the flags alone can't be trusted.
    func start(watching root: URL) -> AsyncStream<[URL]> {
        stop()

        let (eventStream, continuation) = AsyncStream<[URL]>.makeStream()
        let fwd = Forwarder(continuation: continuation)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(fwd).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // No `kFSEventStreamCreateFlagIgnoreSelf`: Athena's own editor saves
        // are the primary events this watch exists to see.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventsCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,   // latency: coalesce bursts (git checkout, build output)
            flags
        ) else {
            continuation.finish()
            return eventStream
        }

        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .userInitiated))
        FSEventStreamStart(created)
        stream = created
        forwarder = fwd
        return eventStream
    }

    /// Stops the active watch and finishes its stream. Safe to call when no
    /// watch exists.
    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        forwarder?.continuation.finish()
        forwarder = nil
    }

    // MARK: - C callback

    private static let eventsCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let forwarder = Unmanaged<Forwarder>.fromOpaque(info).takeUnretainedValue()
        // `kFSEventStreamCreateFlagUseCFTypes` → `eventPaths` is a CFArray of CFString.
        guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else { return }

        var changed: [URL] = []
        for i in 0..<numEvents where i < paths.count {
            // Directory-level events (create/chmod on a folder) carry no
            // uploadable content of their own — the files inside get events too.
            guard eventFlags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }
            let path = paths[i]
            // Skip dot-entries (.git, .DS_Store, .sass-cache…) and
            // node_modules at any depth of the changed path.
            let components = path.split(separator: "/")
            guard !components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) else { continue }
            guard let name = components.last, !isTransientArtifact(String(name)) else { continue }
            changed.append(URL(fileURLWithPath: path))
        }
        if !changed.isEmpty { forwarder.continuation.yield(changed) }
    }

    // MARK: - Transient-artifact filter

    /// Files that exist only for an instant around a save and must never be
    /// uploaded (or remote-DELETEd once they vanish): macOS safe-save
    /// temporaries — `name.sb-1a2b3c4d-Ef5gH6`, which Athena's own atomic
    /// writes (`FileService.writeFile`) drop next to the target file —
    /// `.tmp` rename sources, and `name~` editor backups.
    static func isTransientArtifact(_ fileName: String) -> Bool {
        if fileName.hasSuffix("~") || fileName.hasSuffix(".tmp") { return true }
        guard let range = fileName.range(of: ".sb-", options: .backwards) else { return false }
        let parts = fileName[range.upperBound...].split(separator: "-")
        return parts.count == 2
            && parts[0].count == 8 && parts[0].allSatisfy(\.isHexDigit)
            && parts[1].count == 6 && parts[1].allSatisfy { $0.isLetter || $0.isNumber }
    }
}
