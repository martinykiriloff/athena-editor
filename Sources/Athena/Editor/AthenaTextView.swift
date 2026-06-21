// AthenaTextView.swift
// Custom NSTextView subclass that intercepts Cmd+Click for import navigation.

import AppKit

final class AthenaTextView: NSTextView {

    /// Called with the character index when the user Cmd+Clicks anywhere in the view.
    var onCmdClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Intercept Cmd+Click before the superclass creates a discontiguous selection.
        if event.modifierFlags.contains(.command) {
            let point   = convert(event.locationInWindow, from: nil)
            let charIdx = characterIndex(for: point)
            if charIdx != NSNotFound {
                onCmdClick?(charIdx)
            }
            // Still call super so the cursor moves normally.
            super.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}
