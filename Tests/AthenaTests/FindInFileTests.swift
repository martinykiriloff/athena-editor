// FindInFileTests.swift
// Athena — regression tests for the ⌘F path: key combo -> KeyAction ->
// editor command notification -> Coordinator (isFocusedGroup gate) -> FindReplaceController.
// Swift 6, strict concurrency.

@preconcurrency import AppKit
import Testing
import SwiftUI
@testable import Athena

@Suite("Find in file (⌘F)")
@MainActor
struct FindInFileTests {
    private func makeRig(focused: Bool) -> (EditorView.Coordinator, NSTextView, FindReplaceController, NSWindow) {
        let view = EditorView(content: .constant("hello world"), language: .swift, isFocusedGroup: focused)
        let coord = view.makeCoordinator()
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.string = "hello world"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tv
        let controller = FindReplaceController()
        controller.textView = tv
        coord.textView = tv
        coord.findReplaceController = controller
        coord.installCommandObserver()
        return (coord, tv, controller, window)
    }

    @Test func cmdFResolvesToFindInFile() {
        // keyCode 3 = "f"
        let combo = KeyCombo.from(keyCode: 3, modRaw: NSEvent.ModifierFlags.command.rawValue, chars: "f")
        let binding = KeyBinding.vscodeDefaults.first { $0.combo == combo }
        #expect(binding?.action == .findInFile)
    }

    @Test func findCommandOpensBarInFocusedGroup() async {
        let (coord, _, controller, window) = makeRig(focused: true)
        _ = (coord, window)
        NotificationCenter.default.post(name: .athenaEditorCommand, object: EditorCommand.find)
        #expect(controller.isVisible)
    }

    @Test func findCommandIgnoredInUnfocusedGroup() async {
        let (coord, _, controller, window) = makeRig(focused: false)
        _ = (coord, window)
        NotificationCenter.default.post(name: .athenaEditorCommand, object: EditorCommand.find)
        #expect(!controller.isVisible)
    }

    @Test func performFindInFileReachesEditor() async {
        let (coord, _, controller, window) = makeRig(focused: true)
        _ = (coord, window)
        let state = AppState()
        await state.perform(.findInFile)
        #expect(controller.isVisible)
    }

    // MARK: - Hosted SwiftUI integration

    private func allSubviews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allSubviews) }

    private func pump() async throws {
        let clock = ContinuousClock()
        for _ in 0..<20 {
            try await clock.sleep(until: clock.now.advanced(by: .milliseconds(50)))
        }
    }

    /// Mounts the real `EditorContainerView` (SwiftUI + EditorView + overlay)
    /// in an offscreen window and checks the find bar's field appears.
    @Test func cmdFShowsFindBarInHostedEditor() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("find-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.ts")
        try "const hello = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let state = AppState()
        await state.openFile(file)
        #expect(state.focusedTab != nil)

        let host = NSHostingView(rootView: EditorContainerView().environment(state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await pump()

        func hasFindField() -> Bool {
            allSubviews(host).compactMap { $0 as? NSTextField }.contains {
                $0.placeholderString == "Find" || $0.placeholderAttributedString?.string == "Find"
            }
        }
        #expect(!hasFindField())
        await state.perform(.findInFile)
        try await pump()
        let fields = allSubviews(host).compactMap { $0 as? NSTextField }
        #expect(hasFindField(), "text fields: \(fields.map { $0.placeholderString ?? $0.stringValue })")
        window.orderOut(nil)
    }
}
