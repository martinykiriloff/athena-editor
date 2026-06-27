// AthenaTextView.swift
// Custom NSTextView subclass that intercepts Cmd+Click for import navigation,
// shows a pointing-hand cursor while Cmd-hovering a clickable target, and
// routes keyDown through the completion/ghost-text system.
// Swift 6, strict concurrency.

import AppKit

final class AthenaTextView: NSTextView {

    /// Called with the character index when the user Cmd+Clicks anywhere in the view.
    var onCmdClick: ((Int) -> Void)?

    /// Return `true` to consume the key event (completion popup, ghost text accept, etc.).
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Called on every mouseDown so the coordinator can dismiss popups before the click lands.
    var onMouseDown: (() -> Void)?

    /// Returns `true` when the character index is a Cmd-clickable navigation
    /// target (an import path or a code identifier). Drives the pointing-hand
    /// cursor shown while Cmd is held, mirroring VS Code.
    var isClickableTarget: ((Int) -> Bool)?

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
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

    // MARK: - Cmd+hover cursor

    /// Tracks the whole visible rect so we receive `mouseMoved` regardless of the
    /// window's `acceptsMouseMovedEvents` setting.
    private var hoverTrackingArea: NSTrackingArea?
    /// Last mouse location in view coordinates, so we can re-evaluate the cursor
    /// when the Cmd modifier toggles without the mouse moving.
    private var lastMouseLocation: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        updateHoverCursor(modifierFlags: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastMouseLocation = nil
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Cmd pressed/released without moving the mouse: refresh the cursor in place.
        updateHoverCursor(modifierFlags: event.modifierFlags)
    }

    /// Shows the pointing-hand cursor when Cmd is held over a clickable target,
    /// otherwise restores the I-beam.
    private func updateHoverCursor(modifierFlags: NSEvent.ModifierFlags) {
        guard let location = lastMouseLocation else { return }

        if modifierFlags.contains(.command) {
            let charIdx = characterIndex(for: location)
            if charIdx != NSNotFound, isClickableTarget?(charIdx) == true {
                NSCursor.pointingHand.set()
                return
            }
        }
        NSCursor.iBeam.set()
    }
}
