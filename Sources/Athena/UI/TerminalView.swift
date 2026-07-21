// TerminalView.swift — SwiftTerm-based integrated terminal (Swift 6).
// Wraps one SwiftTerm `LocalProcessTerminalView` bound to a `TerminalSession`
// (plan.md item 21) — SwiftTerm has no notion of running multiple shells in
// one view, so each terminal tab needs its own instance.

import SwiftUI
import AppKit
import SwiftTerm
import Synchronization

struct TerminalView: NSViewRepresentable {
    let session: TerminalSession
    var isActive: Bool

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: .zero)

        tv.font = NSFont(name: "JetBrains Mono", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        tv.nativeBackgroundColor = NSColor(calibratedRed: 0.118, green: 0.133, blue: 0.161, alpha: 1)
        tv.nativeForegroundColor = NSColor(calibratedRed: 0.678, green: 0.733, blue: 0.820, alpha: 1)

        tv.processDelegate = context.coordinator

        // `-i -l`: SwiftTerm's default environment (`Terminal.getEnvironmentVariables`)
        // deliberately excludes `PATH`, and without `-l` (login) the shell never
        // sources `~/.zprofile` (where Homebrew's `shellenv` typically lives) or,
        // without `-i` (interactive), `~/.zshrc` (where nvm/rbenv/pyenv-style
        // version managers install their shims) — so previously every non-builtin
        // command failed with "command not found". Passing both makes the shell
        // resolve its own PATH exactly as a real Terminal.app window would,
        // independent of whatever minimal environment this process inherited.
        tv.startProcess(
            executable: session.shell,
            args: ["-i", "-l"],
            environment: nil,
            execName: nil,
            currentDirectory: session.currentDirectory
        )

        return tv
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Focus the active session's shell so typing reaches it right after
        // switching tabs. `BottomPanelView` keeps every session's view
        // mounted (just hidden via opacity) so this fires on every relevant
        // switch without re-creating anything.
        if isActive, nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    /// Explicitly kills this session's shell when its view leaves the
    /// hierarchy (its terminal tab was closed). `LocalProcess` only cancels
    /// its exit-event monitor on deinit — it never signals the child — so
    /// without this a closed terminal tab would leak its shell as an
    /// orphaned background process for the rest of the app's run. Detaching
    /// the delegate first ensures the resulting exit event can't reach
    /// `Coordinator.processTerminated` and auto-restart a shell for a tab
    /// that's already gone. Also cancels any exec-failure retry already
    /// scheduled by a previous `processTerminated` call — see
    /// `Coordinator.pendingRetry`.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.cancelPendingRetry()
        nsView.processDelegate = nil
        nsView.terminate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shell: session.shell, currentDirectory: session.currentDirectory)
    }

    // LocalProcessTerminalViewDelegate predates Swift concurrency — all four methods are nonisolated.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let shell: String
        let currentDirectory: String?
        /// Consecutive exec failures (exit code 127 — "command not found",
        /// what the forked child reports when `execve` itself fails). A
        /// normal user-initiated `exit` doesn't produce 127, so this only
        /// trips for a shell that can't launch at all; without it, that case
        /// retried unconditionally every 0.3s forever with no visible error.
        private var consecutiveExecFailures = 0
        private static let maxConsecutiveExecFailures = 3
        /// Advanced by `cancelPendingRetry()` and by every `processTerminated`
        /// call. A scheduled retry/feed closure captures the generation it
        /// was created under and compares against the current value when it
        /// finally runs; a mismatch means the coordinator moved on (the tab
        /// was closed, or another failure superseded it) since it was
        /// scheduled, so it no-ops instead of touching a torn-down view.
        /// `dismantleNSView` runs synchronously (nils the delegate, then
        /// calls `terminate()`) but neither of those cancels an
        /// already-scheduled `asyncAfter` block — without this, closing a
        /// tab within 0.3s of its shell failing to exec let the retry fire
        /// afterward and call `startProcess` on a `LocalProcessTerminalView`
        /// that had already been torn down. A dedicated `Sendable` token
        /// (rather than a plain `var` read through `self`) because SwiftTerm
        /// calls `processTerminated` from an undocumented, possibly
        /// background thread — `Coordinator` itself is neither `Sendable`
        /// nor actor-isolated, so Swift 6 correctly refuses to let it be
        /// captured into the `DispatchQueue.main` closures below, which run
        /// in an inferred main-actor context.
        private let retryGeneration = RetryGeneration()

        init(shell: String, currentDirectory: String?) {
            self.shell = shell
            self.currentDirectory = currentDirectory
        }

        func cancelPendingRetry() {
            retryGeneration.advance()
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            consecutiveExecFailures = exitCode == 127 ? consecutiveExecFailures + 1 : 0
            let generation = retryGeneration.advance()
            let token = retryGeneration

            guard consecutiveExecFailures <= Self.maxConsecutiveExecFailures else {
                let shell = shell
                DispatchQueue.main.async { [weak source] in
                    guard token.isCurrent(generation) else { return }
                    source?.feed(text: "\r\n\u{1b}[31m[Athena] '\(shell)' couldn't be started after "
                        + "\(Self.maxConsecutiveExecFailures) attempts — check that it's a valid, "
                        + "executable shell path.\u{1b}[0m\r\n")
                }
                return
            }

            let shell = shell
            let currentDirectory = currentDirectory
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak source] in
                guard token.isCurrent(generation) else { return }
                guard let tv = source as? LocalProcessTerminalView else { return }
                tv.startProcess(
                    executable: shell,
                    args: ["-i", "-l"],
                    environment: nil,
                    execName: nil,
                    currentDirectory: currentDirectory
                )
            }
        }
    }
}

/// Thread-safe generation counter shared between a `TerminalView.Coordinator`
/// and its scheduled exec-failure retry/feed closures — see
/// `Coordinator.retryGeneration`. Genuinely `Sendable` (no `@unchecked`
/// needed): its only state is an `Atomic<Int>`, which is safe to mutate
/// concurrently by construction.
private final class RetryGeneration: Sendable {
    private let value = Atomic<Int>(0)

    /// Invalidates any generation captured before this call and returns the
    /// new current generation.
    @discardableResult
    func advance() -> Int {
        let next = value.load(ordering: .relaxed) + 1
        value.store(next, ordering: .relaxed)
        return next
    }

    func isCurrent(_ generation: Int) -> Bool {
        value.load(ordering: .relaxed) == generation
    }
}
