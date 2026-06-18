// AthenaLayoutManager.swift — custom NSLayoutManager that draws · for spaces and → for tabs.

import AppKit

final class AthenaLayoutManager: NSLayoutManager {

    var dotColor: NSColor = NSColor.gray
    var showWhitespace: Bool = true

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
