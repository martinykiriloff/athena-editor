// AthenaLayoutManager.swift — custom NSLayoutManager that draws · for spaces and → for tabs.

import AppKit

/// Virtual text appended after a line. `isAction` ones are clickable links.
struct LineAnnotation: Equatable, Sendable {
    var text: String
    var isAction: Bool = false
}

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

    // MARK: - Line annotations (virtual text)

    /// 1-based line → text drawn after the line's last glyph. Never enters
    /// the text storage, so edits, undo and highlighting never see it.
    private(set) var lineAnnotations: [Int: LineAnnotation] = [:]
    /// Rects (text-view coordinates) of action annotations from the last draw.
    private(set) var actionRects: [Int: NSRect] = [:]

    func setLineAnnotations(_ new: [Int: LineAnnotation]) {
        guard new != lineAnnotations else { return }
        lineAnnotations = new
        actionRects = [:]
        for tc in textContainers { for tv in [tc.textView].compactMap({ $0 }) { tv.needsDisplay = true } }
    }

    /// The 1-based line whose clickable annotation contains `point`, if any.
    func actionAnnotationLine(at point: NSPoint) -> Int? {
        actionRects.first { $0.value.contains(point) }?.key
    }

    private func drawLineAnnotations(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !lineAnnotations.isEmpty, let textStorage else { return }
        let ns = textStorage.string as NSString
        let baseFont = (textStorage.length > 0 ? textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let font = NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: max(9, baseFont.pointSize - 2), weight: .regular),
                                                toHaveTrait: .italicFontMask)
        let wanted = Set(lineAnnotations.keys)
        var line = 1
        var idx = 0
        while idx <= ns.length, line <= (wanted.max() ?? 0) {
            let range = ns.lineRange(for: NSRange(location: min(idx, ns.length), length: 0))
            if let annotation = lineAnnotations[line], range.length > 0 {
                let glyphRange = self.glyphRange(forCharacterRange: NSRange(location: range.location, length: range.length),
                                                 actualCharacterRange: nil)
                if NSIntersectionRange(glyphRange, glyphsToShow).length > 0 || glyphRange.location == glyphsToShow.location {
                    let lastGlyph = max(glyphRange.location, NSMaxRange(glyphRange) - 1)
                    var used = lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
                    // Exclude the trailing newline glyph's width.
                    if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 0x0A, lastGlyph > glyphRange.location {
                        let loc = location(forGlyphAt: lastGlyph)
                        used.size.width = min(used.size.width, loc.x)
                    }
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: annotation.isAction ? NSColor.systemBlue : NSColor.secondaryLabelColor.withAlphaComponent(0.8),
                    ]
                    let text = annotation.text as NSString
                    let size = text.size(withAttributes: attrs)
                    let x = origin.x + used.maxX + 24
                    let y = origin.y + used.minY + (used.height - size.height) / 2
                    text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                    if annotation.isAction {
                        actionRects[line] = NSRect(x: x, y: y, width: size.width, height: size.height)
                    }
                }
            } else if let annotation = lineAnnotations[line], annotation.isAction, range.length == 0 {
                // empty last line: nothing to anchor to
            }
            idx = NSMaxRange(range)
            if range.length == 0 { break }
            line += 1
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
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
        drawLineAnnotations(forGlyphRange: glyphsToShow, at: origin)

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
