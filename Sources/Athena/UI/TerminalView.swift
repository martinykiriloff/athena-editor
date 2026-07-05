// TerminalView.swift — SwiftTerm-based integrated terminal (Swift 6).
// Wraps one SwiftTerm `LocalProcessTerminalView` bound to a `TerminalSession`
// (plan.md item 21) — SwiftTerm has no notion of running multiple shells in
// one view, so each terminal tab needs its own instance.

import SwiftUI
import AppKit
import SwiftTerm

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

        tv.startProcess(executable: session.shell, args: [], environment: nil, execName: nil)

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
    /// that's already gone.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.processDelegate = nil
        nsView.terminate()
    }

    func makeCoordinator() -> Coordinator { Coordinator(shell: session.shell) }

    // LocalProcessTerminalViewDelegate predates Swift concurrency — all four methods are nonisolated.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let shell: String

        init(shell: String) {
            self.shell = shell
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            let shell = shell
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let tv = source as? LocalProcessTerminalView else { return }
                tv.startProcess(executable: shell, args: [], environment: nil, execName: nil)
            }
        }
    }
}
