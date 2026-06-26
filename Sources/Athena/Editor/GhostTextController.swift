// GhostTextController.swift
// Athena — Inline ghost text overlay for AI-powered predictive completion.
// Swift 6, strict concurrency.

import AppKit

// MARK: - GhostTextController

/// Manages a dimmed `NSTextField` subview of the text view that renders
/// an AI-suggested continuation. Tab accepts; any other key dismisses.
@MainActor
final class GhostTextController {

    // MARK: Public state

    var hasSuggestion: Bool { !suggestion.isEmpty }
    private(set) var suggestion: String = ""

    // MARK: Private

    private weak var ghostLabel: NSTextField?

    // MARK: - Setup

    func install(label: NSTextField) {
        ghostLabel = label
    }

    // MARK: - Display

    func show(text: String, after cursorIdx: Int, font: NSFont, in textView: NSTextView) {
        guard let label = ghostLabel, !text.isEmpty else { return }

        // Only show the first line of a multi-line suggestion inline.
        let inline = text.components(separatedBy: "\n").first ?? text
        guard !inline.isEmpty else { return }

        suggestion = inline

        // Convert cursor screen rect to text-view local coordinates.
        guard let window = textView.window else { return }
        var actual = NSRange()
        let screenRect = textView.firstRect(
            forCharacterRange: NSRange(location: cursorIdx, length: 0),
            actualRange: &actual
        )
        guard screenRect != .zero else { return }

        let windowRect = window.convertFromScreen(screenRect)
        let tvRect     = textView.convert(windowRect, from: nil)

        let attrs: [NSAttributedString.Key: Any] = [
            .font:            font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        label.attributedStringValue = NSAttributedString(string: inline, attributes: attrs)
        // Width 600 to accommodate long suggestions without clipping.
        let height = max(tvRect.height, font.pointSize * 1.5)
        label.frame    = CGRect(x: tvRect.minX, y: tvRect.minY, width: 600, height: height)
        label.alphaValue = 0.55
    }

    // MARK: - Accept / Dismiss

    /// Inserts the current suggestion at the cursor and dismisses.
    /// Returns true if text was inserted.
    func accept(in textView: NSTextView) -> Bool {
        guard !suggestion.isEmpty, let ts = textView.textStorage else { return false }
        let cursorLoc = textView.selectedRange().location
        let insertText = suggestion
        ts.beginEditing()
        ts.replaceCharacters(
            in: NSRange(location: cursorLoc, length: 0),
            with: insertText
        )
        ts.endEditing()
        textView.setSelectedRange(NSRange(location: cursorLoc + insertText.count, length: 0))
        dismiss()
        return true
    }

    func dismiss() {
        suggestion = ""
        ghostLabel?.alphaValue = 0
        ghostLabel?.stringValue = ""
    }
}
