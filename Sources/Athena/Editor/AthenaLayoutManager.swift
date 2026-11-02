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

    // MARK: - Line-end annotations (inlay hints, code lens)

    /// One piece of dim text drawn after the end of a line. Never part of the
    /// text storage. `lensID` marks clickable code-lens segments.
    struct LineAnnotation: Equatable {
        var text: String
        var lensID: UUID?
    }

    /// Annotations keyed by 0-based line.
    private(set) var lineAnnotations: [Int: [LineAnnotation]] = [:]
    var annotationColor: NSColor = NSColor.gray.withAlphaComponent(0.8)
    /// Where each clickable segment was last drawn, in text-container coordinates.
    private(set) var annotationHitRects: [(rect: NSRect, id: UUID)] = []
    /// Cached start offsets of every line; dropped on any character edit.
    private var cachedLineStarts: [Int]?

    func setLineAnnotations(_ annotations: [Int: [LineAnnotation]]) {
        guard annotations != lineAnnotations else { return }
        lineAnnotations = annotations
        annotationHitRects = []
        let length = textStorage?.length ?? 0
        if length > 0 { invalidateDisplay(forCharacterRange: NSRange(location: 0, length: length)) }
    }

    /// The code lens drawn under `point` (text-container coordinates), if any.
    func lensID(at point: NSPoint) -> UUID? {
        annotationHitRects.first { $0.rect.contains(point) }?.id
    }

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int,
                                 invalidatedRange invalidatedCharRange: NSRange) {
        if editMask.contains(.editedCharacters) { cachedLineStarts = nil }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    private func lineStarts() -> [Int] {
        if let cachedLineStarts { return cachedLineStarts }
        let ns = (textStorage?.string ?? "") as NSString
        var starts = [0]
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 0x0A { starts.append(i + 1) }
            i += 1
        }
        cachedLineStarts = starts
        return starts
    }

    private func drawLineAnnotations(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !lineAnnotations.isEmpty, let textStorage else { return }
        let starts = lineStarts()
        let length = textStorage.length
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for (line, items) in lineAnnotations where starts.indices.contains(line) {
            let lineStart = starts[line]
            let lineEnd = line + 1 < starts.count ? starts[line + 1] - 1 : length   // index of the newline
            guard lineEnd >= visible.location - 1, lineStart <= NSMaxRange(visible) else { continue }
            let rect: NSRect
            if lineEnd < length {
                let g = glyphIndexForCharacter(at: lineEnd)
                guard g < numberOfGlyphs else { continue }
                rect = lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
            } else if lineEnd > lineStart, numberOfGlyphs > 0 {
                rect = lineFragmentUsedRect(forGlyphAt: numberOfGlyphs - 1, effectiveRange: nil)
            } else {
                rect = extraLineFragmentUsedRect
            }
            guard rect.height > 0 else { continue }
            let probe = max(min(lineEnd - 1, length - 1), 0)
            let baseFont = length > 0 ? (textStorage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont) : nil
            let font = NSFont.monospacedSystemFont(ofSize: (baseFont?.pointSize ?? 14) * 0.85, weight: .regular)
            var x = rect.maxX + 24
            for item in items {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: annotationColor]
                let size = (item.text as NSString).size(withAttributes: attrs)
                let y = rect.minY + (rect.height - size.height) / 2
                (item.text as NSString).draw(at: NSPoint(x: origin.x + x, y: origin.y + y), withAttributes: attrs)
                if let id = item.lensID {
                    annotationHitRects.removeAll { $0.id == id }
                    annotationHitRects.append((NSRect(x: x, y: rect.minY, width: size.width, height: rect.height), id))
                }
                x += size.width + 12
            }
        }
    }

    // MARK: - Semantic token colours

    /// Applies semantic-token foreground colours as temporary attributes:
    /// display-only, so neither the text storage nor the regex highlighter's
    /// attributes are touched. Pass `[]` to clear.
    func setSemanticColors(_ colored: [(range: NSRange, color: NSColor)]) {
        let length = textStorage?.length ?? 0
        if length > 0 { removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length)) }
        for item in colored where item.range.length > 0 && NSMaxRange(item.range) <= length {
            addTemporaryAttribute(.foregroundColor, value: item.color, forCharacterRange: item.range)
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
