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
    /// The full suggestion (every line) — what `accept()` inserts. Display
    /// splits this across `ghostLabel` (first line, inline at the cursor)
    /// and `continuationLabel` (remaining lines, full-width block below).
    private(set) var suggestion: String = ""

    // MARK: Private

    private weak var ghostLabel: NSTextField?
    /// Lazily created on first multi-line suggestion, as a subview of
    /// whichever `NSTextView` is showing a suggestion — `ghostLabel` alone
    /// can't represent lines after the first: it's anchored at the cursor's
    /// X, but a real second line of code starts at column 0, not the
    /// cursor's column.
    private weak var continuationLabel: NSTextField?

    // MARK: - Setup

    func install(label: NSTextField) {
        ghostLabel = label
    }

    // MARK: - Display

    func show(text: String, after cursorIdx: Int, font: NSFont, in textView: NSTextView) {
        guard let label = ghostLabel, !text.isEmpty else { return }

        suggestion = text

        let lines     = text.components(separatedBy: "\n")
        let firstLine = lines[0]
        let restLines = lines.dropFirst().joined(separator: "\n")

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
        label.attributedStringValue = NSAttributedString(string: firstLine, attributes: attrs)
        // Width 600 to accommodate long suggestions without clipping.
        let lineHeight = max(tvRect.height, font.pointSize * 1.5)
        label.frame    = CGRect(x: tvRect.minX, y: tvRect.minY, width: 600, height: lineHeight)
        label.alphaValue = 0.55

        guard !restLines.isEmpty else {
            hideContinuation()
            return
        }

        // NSTextView uses a flipped coordinate system (origin top-left, Y
        // increasing downward) — "the next line down" is `+ lineHeight`.
        let field = continuationField(in: textView)
        field.attributedStringValue = NSAttributedString(string: restLines, attributes: attrs)
        let leftX = textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 0)
        let extraLines = lines.count - 1
        field.frame = CGRect(
            x: leftX,
            y: tvRect.minY + lineHeight,
            width: max(textView.bounds.width - leftX - 8, 200),
            height: CGFloat(extraLines) * lineHeight
        )
        field.alphaValue = 0.55
    }

    // MARK: - Accept / Dismiss

    /// Inserts the current (possibly multi-line) suggestion at the cursor
    /// and dismisses. Returns true if text was inserted.
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
        // Reset frame to zero so the invisible label doesn't block hit-testing.
        ghostLabel?.frame = .zero
        hideContinuation()
    }

    // MARK: - Private helpers

    private func hideContinuation() {
        continuationLabel?.alphaValue = 0
        continuationLabel?.stringValue = ""
        continuationLabel?.frame = .zero
    }

    private func continuationField(in textView: NSTextView) -> NSTextField {
        if let existing = continuationLabel { return existing }
        let field = NSTextField(labelWithString: "")
        field.isEditable            = false
        field.isBordered            = false
        field.drawsBackground       = false
        field.isSelectable          = false
        field.alphaValue            = 0
        field.maximumNumberOfLines  = 0
        field.lineBreakMode         = .byClipping
        field.cell?.wraps           = false
        textView.addSubview(field)
        continuationLabel = field
        return field
    }
}
