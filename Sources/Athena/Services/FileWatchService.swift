// FileWatchService.swift
// Athena — watches individual open files and the workspace root directory for
// changes made on disk outside the app (git pull, another editor, a build tool).
// Swift 6, strict concurrency.

import Foundation
import Darwin

// MARK: - FileWatchService

/// Per-open-file + workspace-root `DispatchSource` watching. This is
/// deliberately lighter than an FSEvents whole-tree watch: Athena only needs
/// to know about (a) the files it currently has open and (b) whether the
/// workspace root gained/lost/renamed an entry, both of which a handful of
/// `DispatchSourceFileSystemObject`s cover with no new dependency.
actor FileWatchService {

    // MARK: State

    /// One active `DispatchSource` plus the file descriptor it owns.
    private struct Watch {
        let source: DispatchSourceFileSystemObject
        let descriptor: Int32
    }

    private var fileWatches: [URL: Watch] = [:]
    private var directoryWatch: Watch?

    /// Continuation feeding `eventStream()`; nil until a consumer subscribes.
    /// Only one subscriber is supported at a time (the latest one wins),
    /// matching how `AppState` consumes `LSPManager.diagnosticsStream()` — a
    /// single long-lived Task started at launch.
    private var eventContinuation: AsyncStream<FileWatchEvent>.Continuation?

    // MARK: - Public API

    /// Returns a stream of file-system events for every currently- and
    /// future-watched file/directory.
    func eventStream() -> AsyncStream<FileWatchEvent> {
        AsyncStream { continuation in
            Task { self.storeEventContinuation(continuation) }
        }
    }

    private func storeEventContinuation(_ continuation: AsyncStream<FileWatchEvent>.Continuation) {
        eventContinuation = continuation
    }

    /// Begins watching `url` (a regular file) for writes/deletes/renames.
    /// Replaces any existing watch for the same URL. No-ops if the file
    /// can't be opened (e.g. it doesn't exist).
    func watchFile(_ url: URL) {
        stopWatchingFile(url)
        guard let watch = makeWatch(at: url, mask: [.write, .delete, .rename]) else { return }

        watch.source.setEventHandler { [weak self] in
            Task { await self?.handleFileEvent(url) }
        }
        watch.source.resume()
        fileWatches[url] = watch
    }

    /// Stops watching `url`. Safe to call when no watch exists for it.
    func stopWatchingFile(_ url: URL) {
        guard let watch = fileWatches.removeValue(forKey: url) else { return }
        watch.source.cancel()
    }

    /// Begins watching `url` (a directory) for content changes — any
    /// create/delete/rename of an entry inside it. Replaces any existing
    /// directory watch.
    func watchDirectory(_ url: URL) {
        stopWatchingDirectory()
        guard let watch = makeWatch(at: url, mask: [.write]) else { return }

        watch.source.setEventHandler { [weak self] in
            Task { await self?.handleDirectoryEvent(url) }
        }
        watch.source.resume()
        directoryWatch = watch
    }

    /// Stops the active directory watch, if any.
    func stopWatchingDirectory() {
        directoryWatch?.source.cancel()
        directoryWatch = nil
    }

    /// Stops every active watch — all open-file watches plus the directory
    /// watch. Call when closing a workspace (or switching away from one)
    /// so no stale file descriptors or events outlive it.
    func stopAll() {
        for url in Array(fileWatches.keys) { stopWatchingFile(url) }
        stopWatchingDirectory()
    }

    // MARK: - Watch construction

    private func makeWatch(at url: URL, mask: DispatchSource.FileSystemEvent) -> Watch? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: mask,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setCancelHandler { close(descriptor) }
        return Watch(source: source, descriptor: descriptor)
    }

    // MARK: - Event handling

    /// Reads back the triggering event flags via actor-isolated state (rather
    /// than capturing the non-`Sendable` `DispatchSourceFileSystemObject` in
    /// the escaping event-handler closure above).
    private func handleFileEvent(_ url: URL) {
        guard let watch = fileWatches[url] else { return }
        let flags = watch.source.data

        if flags.contains(.delete) || flags.contains(.rename) {
            eventContinuation?.yield(.fileDeleted(url))
            // The inode this descriptor was watching is gone from this path —
            // an atomic-save tool renaming a temp file over it, or an actual
            // delete. Either way this watch is now stale; tear it down and let
            // the caller decide whether to re-watch (e.g. on next open/save).
            stopWatchingFile(url)
        } else if flags.contains(.write) {
            eventContinuation?.yield(.fileChanged(url))
        }
    }

    private func handleDirectoryEvent(_ url: URL) {
        guard directoryWatch != nil else { return }
        eventContinuation?.yield(.directoryChanged(url))
    }
}
