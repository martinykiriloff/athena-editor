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
    /// Follows the UI zoom (`AppState.sf(13)`) so Cmd+= / Cmd+- resize the
    /// terminal together with the rest of the window.
    var fontSize: CGFloat = 13
    /// Terminal background/foreground follow the editor theme so a light
    /// theme doesn't leave a dark terminal glowing under a light editor.
    var theme: EditorTheme = .athenaDracula

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: .zero)

        tv.font = Self.font(ofSize: fontSize)

        Self.applyColors(theme, to: tv)

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
        if nsView.font.pointSize != fontSize {
            nsView.font = Self.font(ofSize: fontSize)
        }
        if context.coordinator.appliedThemeId != theme.id {
            Self.applyColors(theme, to: nsView)
            context.coordinator.appliedThemeId = theme.id
        }

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

    private static func applyColors(_ theme: EditorTheme, to tv: LocalProcessTerminalView) {
        tv.nativeBackgroundColor = theme.background
        tv.nativeForegroundColor = theme.foreground
        // The 16 ANSI colours: a light theme needs a darker palette or
        // `ls`' yellows and greens vanish into the paper.
        tv.installColors((theme.isDark ? darkANSI : lightANSI).map(ansiColor))
    }

    /// Standard bright-on-dark ANSI palette (One Dark's).
    private static let darkANSI: [UInt32] = [
        0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
        0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
    ]

    /// Dark-on-light ANSI palette (GitHub Light's), readable on parchment.
    private static let lightANSI: [UInt32] = [
        0x24292E, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    ]

    private static func ansiColor(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red:   UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8)  & 0xFF) * 257,
            blue:  UInt16( hex        & 0xFF) * 257
        )
    }

    private static func font(ofSize size: CGFloat) -> NSFont {
        NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shell: session.shell, currentDirectory: session.currentDirectory)
    }

    // LocalProcessTerminalViewDelegate predates Swift concurrency — all four methods are nonisolated.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let shell: String
        let currentDirectory: String?
        /// Theme last pushed into the view by `updateNSView`; `makeNSView`
        /// applies the initial one. Main-thread only (SwiftUI's representable
        /// callbacks), so no synchronisation is needed.
        var appliedThemeId: String = ""
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
