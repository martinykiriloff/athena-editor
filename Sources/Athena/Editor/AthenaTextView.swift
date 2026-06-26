// AthenaTextView.swift
// Custom NSTextView subclass that intercepts Cmd+Click for import navigation
// and routes keyDown through the completion/ghost-text system.
// Swift 6, strict concurrency.

import AppKit

final class AthenaTextView: NSTextView {

    /// Called with the character index when the user Cmd+Clicks anywhere in the view.
    var onCmdClick: ((Int) -> Void)?

    /// Return `true` to consume the key event (completion popup, ghost text accept, etc.).
    var onKeyDown: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point   = convert(event.locationInWindow, from: nil)
            let charIdx = characterIndex(for: point)
            if charIdx != NSNotFound { onCmdClick?(charIdx) }
            super.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
