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

    // MARK: - Folding

    /// Hidden character ranges. The text storage is untouched: glyphs in
    /// these ranges are generated as `.null`, so they take no space, and the
    /// newlines between them stop breaking the line.
    private(set) var foldState = FoldState()
    /// Ellipsis chips drawn for folded headers, in text-view coordinates as
    /// of the last draw, paired with the fold range each one opens.
    private(set) var foldChips: [(rect: NSRect, range: NSRange)] = []
    var foldChipColor: NSColor = NSColor.gray

    /// Replaces the folded set and re-lays out the lines that changed.
    func setFoldState(_ new: FoldState) {
        guard new != foldState else { return }
        let old = foldState
        foldState = new
        let length = textStorage?.length ?? 0
        var changed: NSRange?
        let changedRanges = old.folds.filter { !new.folds.contains($0) } + new.folds.filter { !old.folds.contains($0) }
        for r in changedRanges {
            let clamped = NSIntersectionRange(r, NSRange(location: 0, length: length))
            changed = changed.map { NSUnionRange($0, clamped) } ?? clamped
        }
        guard var range = changed else { return }
        // Cover the header's own line so the chip appears/disappears with it.
        if let ns = textStorage?.string as NSString?, range.location > 0 {
            let lineStart = ns.lineRange(for: NSRange(location: range.location - 1, length: 0)).location
            range = NSUnionRange(range, NSRange(location: lineStart, length: 0))
        }
        invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        foldChips = []
    }

    override func setGlyphs(_ glyphs: UnsafePointer<CGGlyph>,
                            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                            characterIndexes charIndexes: UnsafePointer<Int>,
                            font aFont: NSFont, forGlyphRange glyphRange: NSRange) {
        guard !foldState.isEmpty, glyphRange.length > 0 else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            return
        }
        var adjusted = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        for k in 0..<glyphRange.length where foldState.isHidden(charIndexes[k]) { adjusted[k] = .null }
        adjusted.withUnsafeBufferPointer { buffer in
            super.setGlyphs(glyphs, properties: buffer.baseAddress ?? props, characterIndexes: charIndexes,
                            font: aFont, forGlyphRange: glyphRange)
        }
    }

    /// Keeps folds attached to their text through edits; a fold the edit
    /// touches is opened rather than left hiding changed text.
    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int,
                                 invalidatedRange invalidatedCharRange: NSRange) {
        var dropped: [NSRange] = []
        if editMask.contains(.editedCharacters), !foldState.isEmpty {
            dropped = foldState.applyEdit(edited: newCharRange, delta: delta, newLength: textStorage.length)
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
        for r in dropped {
            let clamped = NSIntersectionRange(r, NSRange(location: 0, length: textStorage.length))
            invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
        }
        if !dropped.isEmpty { foldChips = [] }
    }

    // MARK: - Fold chips

    private func drawFoldChips(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !foldState.merged.isEmpty, let ts = textStorage, let container = textContainers.first else { return }
        let ns = ts.string as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let label = "\u{22EF}" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foldChipColor]
        let labelSize = label.size(withAttributes: attrs)
        for m in foldState.merged where m.location > 0 && NSMaxRange(m) <= ns.length {
            let glyph = glyphIndexForCharacter(at: m.location - 1)
            guard NSLocationInRange(glyph, glyphsToShow) else { continue }
            let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            _ = container
            let chip = NSRect(x: origin.x + used.maxX + 4, y: origin.y + frag.minY + 2,
                              width: labelSize.width + 10, height: max(4, frag.height - 4))
            foldChipColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
            label.draw(at: NSPoint(x: chip.minX + 5, y: chip.minY + (chip.height - labelSize.height) / 2), withAttributes: attrs)
            foldChips.removeAll { $0.range == m }
            foldChips.append((chip, m))
        }
    }

    /// The hidden range whose chip contains `point` (text-view coordinates).
    func foldChipRange(at point: NSPoint) -> NSRange? {
        foldChips.first { $0.rect.contains(point) }?.range
    }

    // MARK: - Indent guides

    var showIndentGuides: Bool = false
    var indentWidth: Int = 4
    var guideColor: NSColor = NSColor.gray.withAlphaComponent(0.3)

    private static func indentInfo(_ ns: NSString, line: NSRange, tab: Int) -> (columns: Int, blank: Bool, tabsOnly: Bool) {
        var cols = 0, i = line.location, sawSpace = false
        let end = NSMaxRange(line)
        while i < end {
            let c = ns.character(at: i)
            if c == 0x20 { cols += 1; sawSpace = true } else if c == 0x09 { cols += tab } else { break }
            i += 1
        }
        let blank = i >= end || ns.character(at: i) == 0x0A || ns.character(at: i) == 0x0D
        return (cols, blank, !sawSpace)
    }

    /// Indent columns for a blank line: the smaller of the nearest non-blank
    /// lines above and below, so guides run unbroken through empty lines.
    private static func blankLineColumns(_ ns: NSString, line: NSRange, tab: Int) -> Int {
        func neighbour(forward: Bool) -> Int? {
            var probe = line
            for _ in 0..<60 {
                if forward {
                    guard NSMaxRange(probe) < ns.length else { return nil }
                    probe = ns.lineRange(for: NSRange(location: NSMaxRange(probe), length: 0))
                } else {
                    guard probe.location > 0 else { return nil }
                    probe = ns.lineRange(for: NSRange(location: probe.location - 1, length: 0))
                }
                let info = indentInfo(ns, line: probe, tab: tab)
                if !info.blank { return info.columns }
            }
            return nil
        }
        let up = neighbour(forward: false), down = neighbour(forward: true)
        switch (up, down) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return 0
        }
    }

    private func drawIndentGuides(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard showIndentGuides, indentWidth > 0, let ts = textStorage, ts.length > 0,
              let container = textContainers.first else { return }
        let ns = ts.string as NSString
        let font = (ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let spaceW = (" " as NSString).size(withAttributes: [.font: font]).width
        let tab = indentWidth
        guideColor.setFill()
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, fragGlyphs, _ in
            let chars = self.characterRange(forGlyphRange: fragGlyphs, actualGlyphRange: nil)
            guard chars.location < ns.length else { return }
            let line = ns.lineRange(for: NSRange(location: chars.location, length: 0))
            let info = Self.indentInfo(ns, line: line, tab: tab)
            let cols = info.blank ? Self.blankLineColumns(ns, line: line, tab: tab) : info.columns
            guard cols > 0 else { return }
            let baseX = origin.x + rect.minX + container.lineFragmentPadding
            var column = 0, k = 0
            while column < cols {
                var x = baseX + CGFloat(column) * spaceW
                if !info.blank, info.tabsOnly, line.location + k < ns.length {
                    let g = self.glyphIndexForCharacter(at: line.location + k)
                    x = origin.x + self.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + self.location(forGlyphAt: g).x
                }
                NSRect(x: x.rounded(), y: origin.y + rect.minY, width: 1, height: rect.height).fill()
                column += tab
                k += 1
            }
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawIndentGuides(forGlyphRange: glyphsToShow, at: origin)
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
        drawFoldChips(forGlyphRange: glyphsToShow, at: origin)

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
