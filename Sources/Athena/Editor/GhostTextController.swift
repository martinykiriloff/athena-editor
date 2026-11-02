// GhostTextController.swift
// Athena — Inline ghost text overlay for AI-powered predictive completion.
// Swift 6, strict concurrency.

@preconcurrency import AppKit

// MARK: - GhostTextController

/// Renders an AI-suggested continuation at the caret and inserts it.
///
/// The first line is a label at the caret. Later lines go in a block below
/// it, inside vertical space reserved through the layout manager (see
/// `GhostLineSpacer`) so they never sit on top of the code that follows.
/// Mid-line, the label is opaque and redraws the rest of the real line after
/// the suggestion, so `foo(|)` reads as `foo(bar|)` while the buffer is
/// untouched.
@MainActor
final class GhostTextController {

    // MARK: Public state

    var hasSuggestion: Bool { !suggestion.isEmpty }
    /// The full suggestion (every line) — what `accept()` inserts.
    private(set) var suggestion: String = ""
    /// UTF-16 location the suggestion starts at (the caret when shown).
    private(set) var anchor: Int = 0
    private(set) var mode: InlineCompletionMode = .endOfLine

    // MARK: Private

    private weak var ghostLabel: NSTextField?
    private weak var continuationLabel: NSTextField?
    private weak var textView: NSTextView?
    private let spacer = GhostLineSpacer()
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var badge: String?

    // MARK: - Setup

    func install(label: NSTextField) {
        ghostLabel = label
    }

    // MARK: - Display

    /// Shows `text` at `anchor`. `badge` (e.g. "2/3") is drawn after the
    /// first line, dimmer, and is never inserted.
    func show(
        text: String,
        at anchor: Int,
        mode: InlineCompletionMode = .endOfLine,
        badge: String? = nil,
        font: NSFont,
        in textView: NSTextView
    ) {
        guard ghostLabel != nil, !text.isEmpty else { return }
        suggestion = text
        self.anchor = anchor
        self.mode = mode
        self.badge = badge
        self.font = font
        self.textView = textView
        layout()
    }

    /// Re-renders after the caret advanced through the start of the
    /// suggestion (type-through or partial accept). Returns `false` — and
    /// dismisses — when `typed` doesn't match the suggestion's start.
    func advance(typed: String) -> Bool {
        guard hasSuggestion, !typed.isEmpty, suggestion.hasPrefix(typed) else {
            dismiss()
            return false
        }
        let rest = String(suggestion.dropFirst(typed.count))
        guard !rest.isEmpty else {
            dismiss()
            return false
        }
        suggestion = rest
        anchor += (typed as NSString).length
        badge = nil
        layout()
        return true
    }

    /// Swaps in another alternative at the same anchor.
    func replace(with text: String, badge: String?) {
        guard hasSuggestion, !text.isEmpty else { return }
        suggestion = text
        self.badge = badge
        layout()
    }

    // MARK: - Accept / Dismiss

    /// Inserts the whole suggestion through the text view's undoable edit
    /// path and dismisses. Returns true if text was inserted.
    func accept(in textView: NSTextView) -> Bool {
        let text = suggestion
        dismiss()
        return Self.insert(text, at: anchor, in: textView)
    }

    /// Inserts `chunk` (a head of the suggestion) without dismissing — the
    /// resulting `textDidChange` advances the suggestion via `advance(typed:)`.
    func acceptChunk(_ chunk: String, in textView: NSTextView) -> Bool {
        guard hasSuggestion, !chunk.isEmpty, suggestion.hasPrefix(chunk) else { return false }
        return Self.insert(chunk, at: anchor, in: textView)
    }

    func dismiss() {
        suggestion = ""
        badge = nil
        ghostLabel?.alphaValue = 0
        ghostLabel?.stringValue = ""
        // Reset frame to zero so the invisible label doesn't block hit-testing.
        ghostLabel?.frame = .zero
        hideContinuation()
        releaseReservedSpace()
    }

    // MARK: - Insertion

    /// `shouldChangeText` → replace → caret → `didChangeText`: one undo step,
    /// the normal change notifications, and no trip through `insertText`
    /// (whose auto-close hook would add a second `)` after a suggested `(`).
    /// The caret is placed before `didChangeText` so `textDidChange`
    /// already sees it after the inserted text.
    @discardableResult
    static func insert(_ text: String, at location: Int, in textView: NSTextView) -> Bool {
        guard let ts = textView.textStorage, location <= ts.length else { return false }
        let range = NSRange(location: location, length: 0)
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: text) else { return false }
        ts.replaceCharacters(in: range, with: text)
        textView.setSelectedRange(NSRange(location: location + (text as NSString).length, length: 0))
        textView.didChangeText()
        textView.breakUndoCoalescing()
        return true
    }

    // MARK: - Layout

    private func layout() {
        guard let label = ghostLabel, let textView, hasSuggestion else { return }

        let lines     = suggestion.components(separatedBy: "\n")
        let firstLine = lines[0]
        let restLines = lines.dropFirst().joined(separator: "\n")

        guard let caretRect = localRect(forCharacterAt: anchor, in: textView) else {
            dismiss()
            return
        }
        let lineHeight = max(caretRect.height, font.pointSize * 1.5)
        let ghostAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.75),
        ]

        let first = NSMutableAttributedString(string: firstLine, attributes: ghostAttrs)
        let right = rightEdge(of: textView)
        if mode == .midLine, let rest = restOfLine(in: textView) {
            // Opaque label: the suggestion, then the real rest of the line in
            // its own colours, covering the original glyphs underneath.
            first.append(rest)
            label.drawsBackground = true
            label.backgroundColor = textView.backgroundColor
        } else {
            label.drawsBackground = false
        }
        if let badge {
            first.append(NSAttributedString(string: "  \(badge)", attributes: [
                .font: NSFont.systemFont(ofSize: max(font.pointSize - 2, 9)),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        label.attributedStringValue = first
        label.lineBreakMode = .byClipping
        let width = min(ceil(first.size().width) + 4, max(right - caretRect.minX, 40))
        label.frame = CGRect(x: caretRect.minX, y: caretRect.minY, width: width, height: lineHeight)
        label.alphaValue = 1

        guard !restLines.isEmpty, mode == .endOfLine else {
            hideContinuation()
            releaseReservedSpace()
            return
        }

        let extraLines = lines.count - 1
        let blockHeight = CGFloat(extraLines) * lineHeight
        reserveSpace(blockHeight, afterLineContaining: anchor, in: textView)

        // NSTextView is flipped: "below" is + y. The reserved gap starts at
        // the bottom of the caret line's last fragment (soft wrap included).
        let gapTop = bottomOfLine(containing: anchor, in: textView) ?? (caretRect.minY + lineHeight)
        let field = continuationField(in: textView)
        field.attributedStringValue = NSAttributedString(string: restLines, attributes: ghostAttrs)
        let leftX = textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 0)
        field.frame = CGRect(x: leftX, y: gapTop, width: max(right - leftX, 200), height: blockHeight)
        field.alphaValue = 1
    }

    /// The caret rect at `location`, in text-view coordinates.
    private func localRect(forCharacterAt location: Int, in textView: NSTextView) -> CGRect? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              location <= (textView.string as NSString).length else { return nil }
        let length = (textView.string as NSString).length
        let origin = textView.textContainerOrigin
        if length == 0 {
            let r = lm.extraLineFragmentRect
            return CGRect(x: r.minX + origin.x, y: r.minY + origin.y, width: 1, height: r.height)
        }
        lm.ensureLayout(forCharacterRange: NSRange(location: min(location, length - 1), length: 1))
        if location == length, lm.extraLineFragmentTextContainer != nil,
           (textView.string as NSString).character(at: length - 1) == 0x0A {
            let r = lm.extraLineFragmentRect
            return CGRect(x: r.minX + origin.x + tc.lineFragmentPadding, y: r.minY + origin.y, width: 1, height: r.height)
        }
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        if location >= length || rect.isEmpty && rect.height == 0 {
            // End of document: the caret sits after the last glyph.
            let last = lm.glyphIndexForCharacter(at: max(length - 1, 0))
            let lastRect = lm.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: tc)
            rect = CGRect(x: lastRect.maxX, y: lastRect.minY, width: 1, height: lastRect.height)
        }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    private func bottomOfLine(containing location: Int, in textView: NSTextView) -> CGFloat? {
        guard let lm = textView.layoutManager else { return nil }
        let ns = textView.string as NSString
        guard ns.length > 0 else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        let lastChar = max(line.location, NSMaxRange(line) - 1)
        guard lastChar < ns.length else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: lastChar)
        let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        return used.maxY + textView.textContainerOrigin.y
    }

    private func rightEdge(of textView: NSTextView) -> CGFloat {
        let visible = textView.visibleRect
        return max(visible.maxX - 8, textView.textContainerInset.width + 200)
    }

    /// The real text from the anchor to the end of its line, with the
    /// buffer's own attributes, for the opaque mid-line label.
    private func restOfLine(in textView: NSTextView) -> NSAttributedString? {
        guard let ts = textView.textStorage, anchor <= ts.length else { return nil }
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: anchor, length: 0))
        var end = NSMaxRange(line)
        while end > anchor, let c = Optional(ns.character(at: end - 1)), c == 0x0A || c == 0x0D { end -= 1 }
        guard end > anchor else { return nil }
        return ts.attributedSubstring(from: NSRange(location: anchor, length: end - anchor))
    }

    // MARK: - Reserved space for multi-line suggestions

    private func reserveSpace(_ height: CGFloat, afterLineContaining location: Int, in textView: NSTextView) {
        guard let lm = textView.layoutManager else { return }
        let ns = textView.string as NSString
        let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        if lm.delegate !== spacer {
            // Only take the delegate slot when nobody else holds it.
            guard lm.delegate == nil else { return }
            lm.delegate = spacer
        }
        let old = spacer.reservedRange
        spacer.reservedRange = line
        spacer.height = height
        if let old, old != line { lm.invalidateLayout(forCharacterRange: old, actualCharacterRange: nil) }
        lm.invalidateLayout(forCharacterRange: line, actualCharacterRange: nil)
        lm.ensureLayout(forCharacterRange: line)
        textView.needsDisplay = true
    }

    private func releaseReservedSpace() {
        guard let range = spacer.reservedRange else { return }
        spacer.reservedRange = nil
        spacer.height = 0
        guard let textView, let lm = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        lm.invalidateLayout(forCharacterRange: clamped.length > 0 ? clamped : NSRange(location: min(range.location, length), length: 0),
                            actualCharacterRange: nil)
        textView.needsDisplay = true
    }

    private func hideContinuation() {
        continuationLabel?.alphaValue = 0
        continuationLabel?.stringValue = ""
        continuationLabel?.frame = .zero
    }

    private func continuationField(in textView: NSTextView) -> NSTextField {
        if let existing = continuationLabel, existing.superview === textView { return existing }
        continuationLabel?.removeFromSuperview()
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

// MARK: - GhostLineSpacer

/// Layout-manager delegate that adds paragraph spacing after one line — the
/// empty band a multi-line suggestion's later lines are drawn into, so they
/// push the following code down instead of overlapping it.
final class GhostLineSpacer: NSObject, NSLayoutManagerDelegate {
    /// UTF-16 range of the caret's line (including its newline), or nil.
    var reservedRange: NSRange?
    var height: CGFloat = 0

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        paragraphSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: NSRect
    ) -> CGFloat {
        guard let range = reservedRange, height > 0 else { return 0 }
        let char = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return NSLocationInRange(char, range) ? height : 0
    }
}
