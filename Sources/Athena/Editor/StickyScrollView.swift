// StickyScrollView.swift
// Athena — overlay at the top of the editor showing the header lines of the scopes
//           that enclose the first visible line. Clicking a row jumps to that header.
// Swift 6, strict concurrency.

@preconcurrency import AppKit

final class StickyScrollView: NSView {

    struct Row {
        var text: NSAttributedString
        var line: Int           // 0-based header line
    }

    var rows: [Row] = [] { didSet { needsDisplay = true } }
    var rowHeight: CGFloat = 20 { didSet { needsDisplay = true } }
    var textInset: CGFloat = 12 { didSet { needsDisplay = true } }
    var backgroundColor: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
    var separatorColor: NSColor = .separatorColor { didSet { needsDisplay = true } }
    /// Fired with the row index and its 0-based line.
    var onSelect: ((Int, Int) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        for (i, row) in rows.enumerated() {
            let y = CGFloat(i) * rowHeight
            let size = row.text.size()
            row.text.draw(at: NSPoint(x: textInset, y: y + (rowHeight - size.height) / 2))
        }
        separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let index = Int(p.y / rowHeight)
        guard rows.indices.contains(index) else { return }
        onSelect?(index, rows[index].line)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim clicks that land on a row; the 1pt border and empty
        // state pass through to the editor below.
        rows.isEmpty ? nil : super.hitTest(point)
    }
}
