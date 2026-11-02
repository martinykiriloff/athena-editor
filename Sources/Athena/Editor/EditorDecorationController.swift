// EditorDecorationController.swift
// Athena — owns code folding, bracket-pair colours, indent guides and sticky scroll for one
//           editor. Computes ranges off the main thread, applies them via the layout manager.
// Swift 6, strict concurrency.

@preconcurrency import AppKit

// MARK: - Fold selection (pure)

/// Which ranges a fold command acts on. Pure so it can be unit tested.
enum FoldSelection {
    /// Innermost expandable range containing `caretLine` that is not yet
    /// collapsed (so repeating the command folds outward).
    static func rangeToFold(ranges: [FoldRange], collapsed: Set<FoldRange>, caretLine: Int) -> FoldRange? {
        ranges.filter { !collapsed.contains($0) && $0.startLine <= caretLine && caretLine <= $0.endLine }
            .max { a, b in a.startLine != b.startLine ? a.startLine < b.startLine : a.endLine > b.endLine }
    }

    /// The collapsed range whose header is `caretLine`.
    static func rangeToUnfold(collapsed: Set<FoldRange>, caretLine: Int) -> FoldRange? {
        collapsed.filter { $0.startLine == caretLine }.max { $0.endLine < $1.endLine }
    }

    /// Ranges at nesting `level` (1-based), except those holding the caret.
    static func rangesAtLevel(_ level: Int, ranges: [FoldRange], caretLine: Int) -> [FoldRange] {
        let depths = FoldingRangeComputer.depths(of: ranges)
        return zip(ranges, depths).filter { r, d in
            d == level && !(r.startLine <= caretLine && caretLine <= r.endLine)
        }.map(\.0)
    }
}

// MARK: - Controller

@MainActor
final class EditorDecorationController {

    // MARK: Wiring

    weak var textView: AthenaTextView?
    weak var scrollView: NSScrollView?
    weak var gutter: GutterView?
    /// Server fold ranges for the open file; nil when unsupported.
    var requestServerFoldRanges: (() async -> [FoldRange]?)?
    /// Reports the 0-based header lines of the folded regions after a change.
    var onFoldedLinesChange: (([Int]) -> Void)?

    // MARK: Configuration

    private(set) var enabled = true
    private var indentGuides = false
    private var bracketColors = false
    private var stickyScroll = false
    private var language: Language = .plaintext
    private var tabSize = 4
    private var theme: EditorTheme = .athenaDracula

    // MARK: State

    private(set) var ranges: [FoldRange] = []
    private var lineStarts: [Int] = [0]
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var pendingRestore: [Int]?
    private var lastReported: [Int] = []
    private var bracketsApplied = false
    private var scrollObserver: NSObjectProtocol?
    private let sticky = StickyScrollView()

    private var layoutManager: AthenaLayoutManager? { textView?.layoutManager as? AthenaLayoutManager }

    // MARK: - Configuration

    /// Called on every SwiftUI update; cheap when nothing changed.
    func configure(enabled: Bool, indentGuides: Bool, bracketColors: Bool, stickyScroll: Bool,
                   language: Language, tabSize: Int, theme: EditorTheme) {
        let structural = enabled != self.enabled || language != self.language
            || bracketColors != self.bracketColors || tabSize != self.tabSize
        let themed = theme != self.theme
        self.enabled = enabled
        self.indentGuides = indentGuides && enabled
        self.bracketColors = bracketColors && enabled
        self.stickyScroll = stickyScroll && enabled
        self.language = language
        self.tabSize = tabSize
        self.theme = theme

        if let lm = layoutManager {
            if lm.showIndentGuides != self.indentGuides || lm.indentWidth != tabSize { textView?.needsDisplay = true }
            lm.showIndentGuides = self.indentGuides
            lm.indentWidth = tabSize
            lm.guideColor = theme.whitespace.withAlphaComponent(0.35)
            lm.foldChipColor = theme.comment
            if themed || lm.showIndentGuides != self.indentGuides { textView?.needsDisplay = true }
        }
        sticky.backgroundColor = theme.background
        sticky.separatorColor = theme.whitespace.withAlphaComponent(0.6)

        if !enabled {
            clearAll()
        } else if structural {
            scheduleRefresh(delay: 0)
        }
        installScrollObserverIfNeeded()
        updateSticky()
    }

    private func clearAll() {
        refreshTask?.cancel()
        generation &+= 1
        ranges = []
        layoutManager?.setFoldState(FoldState())
        removeBracketColors()
        gutter?.foldMarkers = [:]
        sticky.rows = []
        sticky.removeFromSuperview()
        textView?.needsDisplay = true
    }

    private func installScrollObserverIfNeeded() {
        guard scrollObserver == nil, let clip = scrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSticky() }
        }
    }

    // MARK: - Document lifecycle

    /// A different document was loaded into the text view. `foldedLines` are
    /// the header lines to re-fold once ranges are known.
    func documentReplaced(foldedLines: [Int]) {
        ranges = []
        lineStarts = [0]
        pendingRestore = foldedLines.isEmpty ? nil : foldedLines
        lastReported = foldedLines
        gutter?.foldMarkers = [:]
        sticky.rows = []
        guard enabled else { return }
        scheduleRefresh(delay: 0)
    }

    func textChanged() {
        guard enabled else { return }
        scheduleRefresh(delay: 250)
        updateSticky()
    }

    func selectionChanged() {
        guard enabled, let lm = layoutManager, let tv = textView, !lm.foldState.isEmpty else { return }
        let hidden = lm.foldState.folds(hiddenBy: tv.selectedRange())
        guard !hidden.isEmpty else { return }
        var state = lm.foldState
        for r in hidden { state.unfold(r) }
        applyFoldState(state)
    }

    // MARK: - Refresh

    private func scheduleRefresh(delay: Int) {
        refreshTask?.cancel()
        generation &+= 1
        let gen = generation
        guard let tv = textView else { return }
        let text = tv.string
        let language = language, tabSize = tabSize, wantsBrackets = bracketColors
        refreshTask = Task { [weak self] in
            if delay > 0 {
                let clock = ContinuousClock()
                try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(delay)))
            }
            guard !Task.isCancelled, let self else { return }
            let server = await self.requestServerFoldRanges?()
            guard !Task.isCancelled, gen == self.generation else { return }
            let result = await Task.detached(priority: .utility) { () -> (ranges: [FoldRange], starts: [Int], pairing: BracketPairing) in
                var folds: [FoldRange] = []
                if let server, !server.isEmpty { folds = FoldingRangeComputer.normalize(lsp: server, text: text) }
                if folds.isEmpty { folds = FoldingRangeComputer.compute(text: text, language: language, tabSize: tabSize) }
                let starts = FoldingRangeComputer.lineStarts(Array(text.utf16))
                let pairing = wantsBrackets ? BracketScanner.pairing(for: text, language: language) : BracketPairing()
                return (folds, starts, pairing)
            }.value
            guard !Task.isCancelled, gen == self.generation, let tv = self.textView,
                  (tv.string as NSString).length == (text as NSString).length else { return }
            self.apply(ranges: result.ranges, lineStarts: result.starts, pairing: result.pairing)
        }
    }

    private func apply(ranges new: [FoldRange], lineStarts starts: [Int], pairing: BracketPairing) {
        ranges = new
        lineStarts = starts
        guard let lm = layoutManager, let tv = textView else { return }
        let length = (tv.string as NSString).length

        var state = lm.foldState
        if let restore = pendingRestore {
            pendingRestore = nil
            for r in new where restore.contains(r.startLine) {
                if let h = FoldState.hiddenRange(for: r, lineStarts: starts, textLength: length) { state.fold(h) }
            }
        }
        // Folds whose region no longer exists as a foldable range have no
        // arrow to reopen them; open them rather than strand hidden text.
        let valid = Set(new.compactMap { FoldState.hiddenRange(for: $0, lineStarts: starts, textLength: length) })
        for f in state.folds where !valid.contains(f) { state.unfold(f) }
        if state != lm.foldState { applyFoldState(state, userInitiated: false) }

        refreshMarkers()
        if bracketColors { applyBracketColors(pairing) } else { removeBracketColors() }
        updateSticky()
        reportFolds()
    }

    private func refreshMarkers() {
        guard let lm = layoutManager else { return }
        let length = ((textView?.string ?? "") as NSString).length
        var markers: [Int: Bool] = [:]
        for r in ranges {
            let collapsed = FoldState.hiddenRange(for: r, lineStarts: lineStarts, textLength: length)
                .map { lm.foldState.folds.contains($0) } ?? false
            markers[r.startLine + 1] = collapsed
        }
        gutter?.foldMarkers = markers
    }

    // MARK: - Fold operations

    private func applyFoldState(_ state: FoldState, userInitiated: Bool = true) {
        guard let lm = layoutManager, let tv = textView else { return }
        // Keep the caret out of text that is about to be hidden.
        let sel = tv.selectedRange()
        if let covering = state.merged.first(where: { sel.location > $0.location && sel.location <= NSMaxRange($0) }) {
            tv.setSelectedRange(NSRange(location: covering.location, length: 0))
        }
        lm.setFoldState(state)
        refreshMarkers()
        gutter?.needsDisplay = true
        tv.needsDisplay = true
        updateSticky()
        if userInitiated { reportFolds() }
    }

    private func currentFoldedLines() -> [Int] {
        guard let lm = layoutManager else { return [] }
        var lines: [Int] = []
        for f in lm.foldState.folds { lines.append(line(of: f.location)) }
        return Array(Set(lines)).sorted()
    }

    private func reportFolds() {
        let lines = currentFoldedLines()
        guard lines != lastReported else { return }
        lastReported = lines
        onFoldedLinesChange?(lines)
    }

    private func line(of index: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func hidden(_ r: FoldRange) -> NSRange? {
        FoldState.hiddenRange(for: r, lineStarts: lineStarts, textLength: ((textView?.string ?? "") as NSString).length)
    }

    private var collapsedRanges: Set<FoldRange> {
        guard let lm = layoutManager else { return [] }
        return Set(ranges.filter { r in hidden(r).map { lm.foldState.folds.contains($0) } ?? false })
    }

    private var caretLine: Int { line(of: textView?.selectedRange().location ?? 0) }

    func perform(_ command: EditorCommand) {
        guard enabled, let lm = layoutManager else {
            if case .goToMatchingBracket = command { goToMatchingBracket() }
            return
        }
        var state = lm.foldState
        switch command {
        case .fold:
            if let r = FoldSelection.rangeToFold(ranges: ranges, collapsed: collapsedRanges, caretLine: caretLine),
               let h = hidden(r) { state.fold(h) }
        case .unfold:
            if let r = FoldSelection.rangeToUnfold(collapsed: collapsedRanges, caretLine: caretLine),
               let h = hidden(r) { state.unfold(h) }
        case .toggleFold:
            if let r = FoldSelection.rangeToUnfold(collapsed: collapsedRanges, caretLine: caretLine), let h = hidden(r) {
                state.unfold(h)
            } else if let r = FoldSelection.rangeToFold(ranges: ranges, collapsed: collapsedRanges, caretLine: caretLine),
                      let h = hidden(r) {
                state.fold(h)
            }
        case .foldAll:
            for r in ranges { if let h = hidden(r) { state.fold(h) } }
        case .unfoldAll:
            state.removeAll()
        case .foldLevel(let n):
            for r in FoldSelection.rangesAtLevel(n, ranges: ranges, caretLine: caretLine) {
                if let h = hidden(r) { state.fold(h) }
            }
        case .goToMatchingBracket:
            goToMatchingBracket()
            return
        default:
            return
        }
        applyFoldState(state)
    }

    /// Toggles the region whose header is the 1-based gutter `line`.
    func toggleFold(atGutterLine line1: Int) {
        guard enabled, let lm = layoutManager,
              let r = ranges.first(where: { $0.startLine == line1 - 1 }), let h = hidden(r) else { return }
        var state = lm.foldState
        if !state.unfold(h) { state.fold(h) }
        applyFoldState(state)
    }

    /// Opens the fold behind a clicked ellipsis chip.
    func unfoldChip(_ range: NSRange) {
        guard let lm = layoutManager else { return }
        var state = lm.foldState
        state.unfold(range)
        applyFoldState(state)
    }

    // MARK: - Go to matching bracket

    private func goToMatchingBracket() {
        guard let tv = textView else { return }
        let pairs = BracketScanner.pairing(for: tv.string, language: language).pairs
        guard let target = BracketScanner.jumpTarget(pairs: pairs, caret: tv.selectedRange().location) else { return }
        tv.setSelectedRange(NSRange(location: target, length: 0))
        tv.scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    // MARK: - Bracket colours

    private static let bracketPalette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.44, blue: 0.84, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.62, blue: 1.00, alpha: 1),
    ]
    private static let unmatchedColor = NSColor(srgbRed: 1.00, green: 0.07, blue: 0.07, alpha: 0.9)

    private func applyBracketColors(_ pairing: BracketPairing) {
        guard let lm = layoutManager, let tv = textView else { return }
        let length = (tv.string as NSString).length
        // One colour attribute per bracket char is the cost of a pass; very
        // large buffers skip it rather than stall the main thread.
        guard length <= 400_000 else { removeBracketColors(); return }
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        let palette = Self.bracketPalette
        for p in pairing.pairs where p.close < length {
            let c = palette[p.depth % palette.count]
            lm.addTemporaryAttribute(.foregroundColor, value: c, forCharacterRange: NSRange(location: p.open, length: 1))
            lm.addTemporaryAttribute(.foregroundColor, value: c, forCharacterRange: NSRange(location: p.close, length: 1))
        }
        for i in pairing.unmatched where i < length {
            lm.addTemporaryAttribute(.foregroundColor, value: Self.unmatchedColor, forCharacterRange: NSRange(location: i, length: 1))
        }
        bracketsApplied = true
    }

    private func removeBracketColors() {
        guard bracketsApplied, let lm = layoutManager, let tv = textView else { return }
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
        bracketsApplied = false
    }

    // MARK: - Sticky scroll

    func updateSticky() {
        guard enabled, stickyScroll, let tv = textView, let sv = scrollView,
              let lm = tv.layoutManager, let tc = tv.textContainer, !ranges.isEmpty else {
            sticky.rows = []
            sticky.removeFromSuperview()
            return
        }
        let visible = tv.visibleRect
        let origin = tv.textContainerOrigin
        let probe = NSPoint(x: tv.textContainerInset.width + 1, y: max(0, visible.minY - origin.y + 1))
        let glyph = lm.glyphIndex(for: probe, in: tc)
        guard glyph < lm.numberOfGlyphs else { sticky.rows = []; sticky.removeFromSuperview(); return }
        let topLine = line(of: lm.characterIndexForGlyph(at: glyph))
        let scopes = ranges.filter { $0.startLine < topLine && topLine <= $0.endLine }.suffix(3)
        guard !scopes.isEmpty else { sticky.rows = []; sticky.removeFromSuperview(); return }

        let ts = tv.textStorage
        let length = ts?.length ?? 0
        let rows: [StickyScrollView.Row] = scopes.compactMap { r in
            guard let ts, r.startLine + 1 < lineStarts.count else { return nil }
            let start = lineStarts[r.startLine]
            let end = min(lineStarts[r.startLine + 1] - 1, length)
            guard end >= start else { return nil }
            return StickyScrollView.Row(text: ts.attributedSubstring(from: NSRange(location: start, length: end - start)), line: r.startLine)
        }
        let rowHeight = lm.defaultLineHeight(for: (tv.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))) + 4
        sticky.rowHeight = rowHeight
        sticky.textInset = tv.textContainerInset.width + (tc.lineFragmentPadding)
        sticky.rows = rows

        let clip = sv.contentView.frame
        let height = rowHeight * CGFloat(rows.count) + 1
        let y = sv.isFlipped ? clip.minY : clip.maxY - height
        sticky.frame = NSRect(x: clip.minX, y: y, width: clip.width, height: height)
        sticky.onSelect = { [weak self] index, line in self?.jumpToHeader(line: line, rowIndex: index) }
        if sticky.superview !== sv { sv.addSubview(sticky, positioned: .above, relativeTo: nil) }
    }

    private func jumpToHeader(line: Int, rowIndex: Int) {
        guard let tv = textView, let lm = tv.layoutManager, line < lineStarts.count else { return }
        let loc = lineStarts[line]
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        let glyph = lm.glyphIndexForCharacter(at: min(loc, max(0, (tv.string as NSString).length - 1)))
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // Leave room for the rows that stay stuck above this header.
        let y = rect.minY + tv.textContainerOrigin.y - CGFloat(rowIndex) * sticky.rowHeight
        tv.scroll(NSPoint(x: 0, y: max(0, y)))
        tv.window?.makeFirstResponder(tv)
    }
}
