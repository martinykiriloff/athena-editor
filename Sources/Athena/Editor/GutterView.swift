// GutterView.swift
// Athena — NSRulerView subclass that renders line numbers, breakpoint dots,
//           and the current debug-line arrow.
// Swift 6, strict concurrency.

import AppKit

// MARK: - GutterView

final class GutterView: NSRulerView {

    // Updated from EditorView coordinator on every render.
    var breakpoints: Set<Int> = []      // 1-based line numbers with a breakpoint
    var debugLine:   Int? = nil         // 1-based line paused on (nil = not paused)
    /// 1-based line numbers with a diagnostic worth a gutter marker, mapped
    /// to the highest severity on that line. Only `.error`/`.warning` land
    /// here — `.information`/`.hint` get no gutter glyph (see
    /// `EditorView.gutterDiagnosticSeverities`), matching the editor's own
    /// "no underline, or a very subtle one" treatment for those severities.
    var diagnostics: [Int: DiagnosticSeverity] = [:]
    /// 1-based line numbers with a git working-tree change relative to
    /// `HEAD`, mapped to its classification — drives the colored change
    /// bar along the gutter's absolute left edge (plan.md item 19, "D4").
    /// Populated from `AppState.gitLineChanges` via `EditorView`, the same
    /// way `diagnostics` above is.
    var gitLineChanges: [Int: GitLineChangeType] = [:]
    /// Used to color the change bar (`diffAdded`/`diffModified`/`diffRemoved`)
    /// — kept in sync with the editor's theme by `EditorView`.
    var theme: EditorTheme = .darcula
    var onToggleBreakpoint: ((Int) -> Void)?

    // Visual constants
    private let gutterWidth:    CGFloat = 52
    private let dotRadius:      CGFloat = 5
    private let changeBarWidth: CGFloat = 3    // git change bar — absolute left edge
    private let diagDotRadius:  CGFloat = 2.5  // small, left-edge — clear of the change bar
    private let numberRightPad: CGFloat = 22  // space for the dot column

    private let numberAttrs: [NSAttributedString.Key: Any] = [
        .font:            NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(white: 0.45, alpha: 1)
    ]

    // MARK: - Init

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = gutterWidth
    }

    required init(coder: NSCoder) { fatalError() }

    override var requiredThickness: CGFloat { gutterWidth }

    // MARK: - Observers

    func installObservers(textView: NSTextView) {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(redraw),
                       name: NSText.didChangeNotification, object: textView)
        nc.addObserver(self, selector: #selector(redraw),
                       name: NSView.boundsDidChangeNotification,
                       object: textView.enclosingScrollView?.contentView)
    }

    @objc private func redraw() { needsDisplay = true }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer
        else { return }

        // Gutter background
        NSColor(white: 0.14, alpha: 1).setFill()
        bounds.fill()

        // Right separator
        NSColor(white: 0.22, alpha: 1).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        let str           = textView.string as NSString
        let visibleRect   = textView.visibleRect
        let originY       = textView.textContainerOrigin.y

        guard let visRange = visibleGlyphRange(lm: lm, tc: tc, visibleRect: visibleRect)
        else { return }

        let visCharStart  = lm.characterRange(forGlyphRange: NSRange(location: visRange.location, length: 0),
                                              actualGlyphRange: nil).location
        let startLine     = lineNumber(in: str, before: visCharStart)

        var glyphIndex = visRange.location
        var lineNum    = startLine

        while glyphIndex < NSMaxRange(visRange) {
            var fragRange = NSRange()
            let fragRect  = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragRange)
            // Convert from text-container coords to ruler coords.
            let rulerY = fragRect.minY + originY - visibleRect.minY

            drawLine(lineNum, rulerY: rulerY, height: fragRect.height)

            glyphIndex = NSMaxRange(fragRange)
            lineNum   += 1
        }
    }

    private func drawLine(_ lineNum: Int, rulerY: CGFloat, height: CGFloat) {
        let isDebugLine = debugLine == lineNum
        let hasBP       = breakpoints.contains(lineNum)

        // Debug line highlight
        if isDebugLine {
            NSColor.systemYellow.withAlphaComponent(0.25).setFill()
            NSRect(x: 0, y: rulerY, width: bounds.width, height: height).fill()
        }

        // Git change bar — thin colored strip along the gutter's absolute
        // left edge for added/modified lines, matching VS Code's gutter
        // change indicator. A pure deletion (no added counterpart) instead
        // draws a small triangular notch at the row's top edge, marking the
        // boundary rather than claiming the whole line's height.
        switch gitLineChanges[lineNum] {
        case .added:
            theme.diffAdded.setFill()
            NSRect(x: 0, y: rulerY, width: changeBarWidth, height: height).fill()
        case .modified:
            theme.diffModified.setFill()
            NSRect(x: 0, y: rulerY, width: changeBarWidth, height: height).fill()
        case .deleted:
            let notchSize: CGFloat = 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: rulerY))
            path.line(to: NSPoint(x: changeBarWidth + notchSize, y: rulerY))
            path.line(to: NSPoint(x: 0, y: rulerY + notchSize))
            path.close()
            theme.diffRemoved.setFill()
            path.fill()
        case nil:
            break
        }

        // Diagnostic marker — small dot at the gutter's left edge, clear of
        // the change bar above and independent of the breakpoint dot/debug
        // arrow (drawn on the right, below), so a line can show all three
        // at once without collision.
        if let severity = diagnostics[lineNum] {
            let color: NSColor = severity == .error ? .systemRed : .systemOrange
            let cx = changeBarWidth + diagDotRadius + 1
            let cy = rulerY + height / 2
            let path = NSBezierPath(ovalIn: NSRect(
                x: cx - diagDotRadius, y: cy - diagDotRadius,
                width: diagDotRadius * 2, height: diagDotRadius * 2
            ))
            color.setFill()
            path.fill()
        }

        // Breakpoint dot or debug arrow
        if hasBP || isDebugLine {
            let cx = gutterWidth - 10
            let cy = rulerY + height / 2
            let path = NSBezierPath()

            if isDebugLine {
                // Arrow pointing right
                let w: CGFloat = 10, h: CGFloat = 8
                path.move(to: NSPoint(x: cx - w / 2, y: cy - h / 2))
                path.line(to: NSPoint(x: cx + w / 2, y: cy))
                path.line(to: NSPoint(x: cx - w / 2, y: cy + h / 2))
                path.close()
                NSColor.systemYellow.setFill()
            } else {
                // Filled circle
                let r = dotRadius
                path.appendOval(in: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                NSColor.systemRed.setFill()
            }
            path.fill()
        }

        // Line number
        let numStr = "\(lineNum)" as NSString
        let attrs  = isDebugLine
            ? numberAttrs.merging([.foregroundColor: NSColor.systemYellow]) { _, new in new }
            : numberAttrs
        let size   = numStr.size(withAttributes: attrs)
        let x      = gutterWidth - numberRightPad - size.width
        let y      = rulerY + (height - size.height) / 2
        numStr.draw(at: NSPoint(x: max(4, x), y: y), withAttributes: attrs)
    }

    // MARK: - Click handling

    // Ruler views must not steal focus — the text view keeps first responder.
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let textView = clientView as? NSTextView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer
        else { return }

        let local    = convert(event.locationInWindow, from: nil)
        let textY    = local.y + textView.visibleRect.minY - textView.textContainerOrigin.y
        let pt       = NSPoint(x: textView.textContainerInset.width, y: max(0, textY))
        let glyphIdx = lm.glyphIndex(for: pt, in: tc)
        let charIdx  = lm.characterIndexForGlyph(at: glyphIdx)
        let str      = textView.string as NSString

        var lineNum  = 1
        var idx      = 0
        while idx < charIdx {
            let range = str.lineRange(for: NSRange(location: idx, length: 0))
            idx = NSMaxRange(range)
            if idx <= charIdx { lineNum += 1 }
        }

        onToggleBreakpoint?(lineNum)

        // Restore focus to the editor so keyboard shortcuts keep working after a gutter click.
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Helpers

    private func visibleGlyphRange(lm: NSLayoutManager, tc: NSTextContainer, visibleRect: NSRect) -> NSRange? {
        let count = lm.numberOfGlyphs
        guard count > 0 else { return nil }
        let range = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        guard range.length > 0 || range.location < count else { return nil }
        return NSRange(location: range.location, length: max(1, range.length))
    }

    private func lineNumber(in str: NSString, before charIndex: Int) -> Int {
        guard charIndex > 0 else { return 1 }
        var line = 1
        var idx  = 0
        while idx < charIndex && idx < str.length {
            let r = str.lineRange(for: NSRange(location: idx, length: 0))
            if NSMaxRange(r) <= charIndex {
                line += 1
                idx   = NSMaxRange(r)
            } else { break }
        }
        return line
    }
}
