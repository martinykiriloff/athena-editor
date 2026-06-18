// TerminalView.swift — SwiftTerm-based integrated terminal (Swift 6).

import SwiftUI
import AppKit
import SwiftTerm

struct TerminalView: NSViewRepresentable {

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: .zero)

        tv.font = NSFont(name: "JetBrains Mono", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        tv.nativeBackgroundColor = NSColor(calibratedRed: 0.118, green: 0.133, blue: 0.161, alpha: 1)
        tv.nativeForegroundColor = NSColor(calibratedRed: 0.678, green: 0.733, blue: 0.820, alpha: 1)

        tv.processDelegate = context.coordinator

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        tv.startProcess(executable: shell, args: [], environment: nil, execName: nil)

        return tv
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    // LocalProcessTerminalViewDelegate predates Swift concurrency — all four methods are nonisolated.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let tv = source as? LocalProcessTerminalView else { return }
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                tv.startProcess(executable: shell, args: [], environment: nil, execName: nil)
            }
        }
    }
}
