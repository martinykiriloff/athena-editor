// MinimapView.swift — scaled-down code overview with viewport indicator and click-to-scroll.

import SwiftUI
import AppKit

// MARK: - EditorScrollProxy

/// Allows external callers (e.g. the minimap) to scroll the editor's NSScrollView.
@MainActor
final class EditorScrollProxy {
    weak var scrollView: NSScrollView?

    func scrollTo(fraction: Double) {
        guard let scrollView, let docView = scrollView.documentView else { return }
        let contentH = docView.frame.height
        let visibleH = scrollView.contentView.bounds.height
        let targetY  = max(0, fraction * (contentH - visibleH))
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

// MARK: - MinimapView (NSViewRepresentable)

struct MinimapView: NSViewRepresentable {
    var content: String
    var language: Language
    var theme: EditorTheme
    var scrollFraction: Double
    var visibleFraction: Double
    var onJump: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MinimapNSView {
        let v = MinimapNSView()
        v.onJump = onJump
        return v
    }

    func updateNSView(_ nsView: MinimapNSView, context: Context) {
        let coord = context.coordinator

        // Re-highlight only when source/language/theme changes (not on every scroll).
        if content != coord.lastContent || language != coord.lastLanguage || theme != coord.lastTheme {
            coord.lastContent  = content
            coord.lastLanguage = language
            coord.lastTheme    = theme
            coord.highlighted  = SyntaxHighlighter(language: language, theme: theme).highlight(content)
        }

        nsView.update(
            attributed:     coord.highlighted,
            bgColor:        theme.background,
            scrollFraction: scrollFraction,
            visibleFraction: visibleFraction
        )
        nsView.onJump = onJump
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator {
        var lastContent:  String        = ""
        var lastLanguage: Language      = .plaintext
        var lastTheme:    EditorTheme   = .darcula
        var highlighted:  NSAttributedString = NSAttributedString()
    }
}

// MARK: - MinimapNSView

final class MinimapNSView: NSView {

    // ── Tunable constants ──────────────────────────────────────────────────────
    private static let lineH:    CGFloat = 2.0   // minimap px per editor line
    private static let charW:    CGFloat = 1.2   // minimap px per character
    private static let padLeft:  CGFloat = 4.0

    // ── State ──────────────────────────────────────────────────────────────────
    var onJump: ((Double) -> Void)?

    private var attributed:     NSAttributedString = NSAttributedString()
    private var bgColor:        NSColor            = .black
    private var scrollFraction: Double = 0
    private var visibleFraction: Double = 0.2

    override var isFlipped: Bool { true }

    // ── Public update ──────────────────────────────────────────────────────────

    func update(attributed: NSAttributedString,
                bgColor: NSColor,
                scrollFraction: Double,
                visibleFraction: Double) {
        self.attributed      = attributed
        self.bgColor         = bgColor
        self.scrollFraction  = scrollFraction
        self.visibleFraction = visibleFraction
        needsDisplay = true
    }

    // ── Drawing ────────────────────────────────────────────────────────────────

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)

        let lh   = Self.lineH
        let cw   = Self.charW
        let pad  = Self.padLeft
        let nsStr = attributed.string as NSString
        let lineCount = nsStr.components(separatedBy: "\n").count
        let totalH = CGFloat(lineCount) * lh
        let viewH  = bounds.height

        // How far the minimap canvas is scrolled to track the editor
        let minimapOffset: CGFloat = totalH > viewH
            ? CGFloat(scrollFraction) * (totalH - viewH)
            : 0

        // Viewport indicator rectangle (in minimap view coordinates)
        let visibleLines = CGFloat(visibleFraction) * CGFloat(lineCount)
        let firstVisible = CGFloat(scrollFraction) * max(0, CGFloat(lineCount) - visibleLines)
        let indicatorY = firstVisible * lh - minimapOffset
        let indicatorH = max(20, visibleLines * lh)

        // ── Draw code lines ─────────────────────────────────────────────────
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -minimapOffset)

        let firstDrawLine = max(0, Int(minimapOffset / lh) - 1)
        let lastDrawLine  = min(lineCount - 1, Int((minimapOffset + viewH) / lh) + 1)

        var charPos = 0
        for li in 0..<lineCount {
            let lineRange = nsStr.lineRange(for: NSRange(location: charPos, length: 0))

            if li >= firstDrawLine && li <= lastDrawLine {
                var x = pad
                let lineY = CGFloat(li) * lh

                attributed.enumerateAttributes(in: lineRange, options: []) { attrs, range, _ in
                    guard range.length > 0 else { return }
                    let color = (attrs[.foregroundColor] as? NSColor) ?? NSColor.gray
                    let segW  = CGFloat(range.length) * cw
                    let drawW = min(segW, bounds.width - pad - x)
                    if drawW > 0 {
                        ctx.setFillColor(color.withAlphaComponent(0.75).cgColor)
                        ctx.fill(CGRect(x: x, y: lineY + 0.3, width: drawW, height: lh - 0.3))
                    }
                    x += segW
                }
            }

            charPos = lineRange.upperBound
        }

        ctx.restoreGState()

        // ── Viewport highlight ───────────────────────────────────────────────
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.fill(CGRect(x: 0, y: indicatorY, width: bounds.width, height: indicatorH))

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.5)
        // Top border
        ctx.move(to: CGPoint(x: 0,             y: indicatorY))
        ctx.addLine(to: CGPoint(x: bounds.width, y: indicatorY))
        // Bottom border
        ctx.move(to: CGPoint(x: 0,             y: indicatorY + indicatorH))
        ctx.addLine(to: CGPoint(x: bounds.width, y: indicatorY + indicatorH))
        ctx.strokePath()
    }

    // ── Mouse interaction ──────────────────────────────────────────────────────

    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }

    private func jump(_ event: NSEvent) {
        let pt       = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, Double(pt.y / bounds.height)))
        onJump?(fraction)
    }

    // Accept mouse events without needing to be first responder
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
