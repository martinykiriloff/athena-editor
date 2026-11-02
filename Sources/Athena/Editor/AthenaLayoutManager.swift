// AthenaLayoutManager.swift — custom NSLayoutManager that draws · for spaces and → for tabs.

import AppKit

final class AthenaLayoutManager: NSLayoutManager {

    var dotColor: NSColor = NSColor.gray
    var showWhitespace: Bool = true

    /// Ranges of the LSP `documentHighlight` occurrences under the caret,
    /// painted behind the glyphs in `drawBackground`. Kept here rather than
    /// as text-storage or temporary `.backgroundColor` attributes so they
    /// can't collide with syntax highlighting, bracket matching or conflict
    /// tints (all of which add/remove `.backgroundColor` over ranges).
    private(set) var symbolHighlightRanges: [NSRange] = []
    var symbolHighlightColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.22)

    func setSymbolHighlights(_ ranges: [NSRange]) {
        guard ranges != symbolHighlightRanges else { return }
        let old = symbolHighlightRanges
        symbolHighlightRanges = ranges
        let length = textStorage?.length ?? 0
        for r in old + ranges where NSMaxRange(r) <= length {
            invalidateDisplay(forCharacterRange: r)
        }
    }

    // MARK: - Tailwind colour bars

    /// Set per file (see `TailwindSupport.supportsSwatches`): paints a thin
    /// bar of the utility's colour under `bg-red-500`-style tokens.
    var tailwindSwatches: Bool = false

    private func drawTailwindColorBars(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard tailwindSwatches, let textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for token in TailwindSupport.colorTokens(in: textStorage.string, range: charRange) {
            let glyphs = glyphRange(forCharacterRange: token.range, actualCharacterRange: nil)
            let color = NSColor(
                srgbRed: CGFloat((token.hex >> 16) & 0xFF) / 255,
                green: CGFloat((token.hex >> 8) & 0xFF) / 255,
                blue: CGFloat(token.hex & 0xFF) / 255,
                alpha: CGFloat(token.alpha))
            color.setFill()
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                let bar = NSRect(x: rect.minX + origin.x, y: rect.maxY + origin.y - 3, width: rect.width, height: 3)
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawTailwindColorBars(forGlyphRange: glyphsToShow, at: origin)
        guard !symbolHighlightRanges.isEmpty, let container = textContainers.first else { return }
        let length = textStorage?.length ?? 0
        symbolHighlightColor.setFill()
        for range in symbolHighlightRanges where range.length > 0 && NSMaxRange(range) <= length {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)

        guard showWhitespace, let textStorage else { return }
        let nsString = textStorage.string as NSString
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        for charIdx in charRange.location ..< NSMaxRange(charRange) {
            let char = nsString.character(at: charIdx)
            let marker: String
            switch char {
            case 0x20: marker = "·"   // space
            case 0x09: marker = "→"   // tab
            default:   continue
            }

            let glyphIdx = glyphIndexForCharacter(at: charIdx)
            guard glyphIdx < numberOfGlyphs else { continue }

            let fragRect = lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            let glyphLoc = location(forGlyphAt: glyphIdx)

            let font = (textStorage.attribute(.font, at: charIdx, effectiveRange: nil) as? NSFont)
                ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

            // glyphLoc.y is the baseline offset from the fragment top in flipped (y-down) coords.
            // NSString.draw(at:) anchors at the upper-left, so subtract ascender to align
            // the dot's top with the text's top, regardless of lineHeightMultiple.
            let drawPoint = NSPoint(
                x: origin.x + fragRect.origin.x + glyphLoc.x,
                y: origin.y + fragRect.origin.y + glyphLoc.y - font.ascender
            )

            (marker as NSString).draw(
                at: drawPoint,
                withAttributes: [.foregroundColor: dotColor, .font: font]
            )
        }
    }
}
