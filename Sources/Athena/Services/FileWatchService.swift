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

    // MARK: - Weak-self box

    /// Opaque, `Sendable`-conforming holder for a weak reference, so a
    /// `DispatchSource` event-handler closure can capture an immutable `let`
    /// instead of a bare `weak var` local. See the note on `watchFile` below
    /// for why this indirection exists.
    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

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
    ///
    /// Builds the stream via `AsyncStream.makeStream()` rather than the
    /// `AsyncStream { continuation in ... }` initializer so the continuation
    /// is stored as a plain, synchronous actor-isolated assignment. The
    /// closure-based initializer requires hopping through a nested `Task` to
    /// touch actor state, which races a `DispatchSource`'s own event handler:
    /// a file event firing before that nested Task is scheduled would find
    /// `eventContinuation` still `nil` and be silently dropped forever — this
    /// was the root cause of this suite's intermittent flakiness.
    func eventStream() -> AsyncStream<FileWatchEvent> {
        let (stream, continuation) = AsyncStream<FileWatchEvent>.makeStream()
        eventContinuation = continuation
        return stream
    }

    /// Begins watching `url` (a regular file) for writes/deletes/renames.
    /// Replaces any existing watch for the same URL. No-ops if the file
    /// can't be opened (e.g. it doesn't exist).
    func watchFile(_ url: URL) {
        stopWatchingFile(url)
        guard let watch = makeWatch(at: url, mask: [.write, .delete, .rename]) else { return }

        // A stricter Swift 6 SDK's region-isolation checker flags a "sending"
        // data-race risk on this closure — a false positive for this
        // well-established weak-self-then-optional-chain idiom: the closure
        // only ever touches `self` through `await` inside a `Task`, which
        // performs a real actor hop. That check (SE-0430 "sending"
        // parameters) is a different mechanism from Sendable-conformance
        // checking, so `nonisolated(unsafe)` — tried directly on a `weak var`
        // and, before that, misapplied to a strong `let` feeding a `[weak x]`
        // capture-list alias — cannot satisfy it: it flags any *bare mutable
        // local* (which `weak var` inherently is) still reachable from the
        // enclosing method as unsendable, regardless of attributes. Routing
        // through `WeakBox`, an opaque `@unchecked Sendable` reference type,
        // means the closure captures an immutable `let` whose declared type
        // is already Sendable — the mutability (the weak slot inside) is no
        // longer visible to the checker at the capture site. Runtime
        // behavior is unchanged: still a weak reference, still resolved at
        // `Task`-execution time via `await`. Two earlier attempts that
        // instead restructured where the capture/`Task` sits (moving it into
        // the inner `Task`, and `Task.detached`) compiled fine but caused a
        // real "Incorrect actor executor assumption" runtime crash, so this
        // fix deliberately keeps the closure/Task nesting itself unchanged.
        let watchSelf = WeakBox(self)
        watch.source.setEventHandler {
            Task { await watchSelf.value?.handleFileEvent(url) }
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

        // See the note on `watchFile` above.
        let watchSelf = WeakBox(self)
        watch.source.setEventHandler {
            Task { await watchSelf.value?.handleDirectoryEvent(url) }
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

        // `.userInitiated`, not `.utility`: the entire point of this watch is
        // timely detection of external changes (avoiding a stale buffer
        // silently overwriting one on save), so its callback must not be the
        // thing macOS deprioritizes first when the machine is busy — `.utility`
        // is explicitly scheduled behind user-facing work and was observed to
        // starve for multiple seconds under concurrent load (e.g. the test
        // suite's ~75 other concurrently-scheduled tasks).
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: mask,
            queue: DispatchQueue.global(qos: .userInitiated)
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
