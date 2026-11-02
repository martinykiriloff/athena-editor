// NextEditDriver.swift
// Athena — next-edit prediction: remembers the last few edits, asks for the
// likely follow-up after a pause, and shows it where it applies.
// Swift 6, strict concurrency.

@preconcurrency import AppKit

// MARK: - NextEditDriver

/// After the user pauses, asks for the edit they will most likely make next
/// (the other uses of a rename, call sites after a signature change…).
/// The model answers with the exact text to replace; it's shown only if
/// that text occurs exactly once near the recent edits and not under the
/// caret. The target is struck through, the replacement previewed below it,
/// and the gutter marks the line. Tab jumps there; Tab again applies.
@MainActor
final class NextEditDriver {

    // MARK: Wiring

    weak var textView: NSTextView?
    var isEnabled: () -> Bool = { false }
    var isGhostVisible: () -> Bool = { false }
    var requestCandidate: @MainActor (NextEditQuery) async -> NextEditCandidate? = { _ in nil }
    var delayMs = 1200

    // MARK: State

    private(set) var prediction: NextEditPrediction?
    private var history: [RecentEdit] = []
    /// The line being edited right now: its number, its text before this
    /// burst of typing, and a location inside it.
    private var burst: (line: Int, before: String, location: Int)?
    private var docVersion = 0
    private var task: Task<Void, Never>?
    private weak var previewLabel: NSTextField?

    private static let historyLimit = 5
    private static let excerptRadius = 40

    // MARK: - Events

    /// From `shouldChangeTextIn`: start (or continue) the current burst.
    func willChangeText(range: NSRange) {
        guard let tv = textView, tv.selectedRanges.count <= 1 else { return }
        let ns = tv.string as NSString
        guard range.location <= ns.length else { return }
        let line = Self.lineNumber(at: range.location, in: ns)
        if burst?.line != line {
            closeBurst()
            burst = (line, Self.lineText(at: range.location, in: ns), range.location)
        }
    }

    func textDidChange() {
        docVersion += 1
        if let current = burst, let tv = textView {
            // Keep the burst's location on its line as text shifts.
            burst?.location = min(current.location, (tv.string as NSString).length)
        }
        clear()
        schedule()
    }

    /// Escape: dismiss a visible prediction.
    func handleEscape() -> Bool {
        guard prediction != nil else { return false }
        clear()
        return true
    }

    /// Tab: first jump to the predicted edit, then apply it.
    func handleTab() -> Bool {
        guard let prediction, let tv = textView else { return false }
        if tv.selectedRange().location != prediction.range.location {
            tv.setSelectedRange(NSRange(location: prediction.range.location, length: 0))
            tv.scrollRangeToVisible(prediction.range)
            layoutPreview(header: "⇥ Tab to apply · Esc to dismiss")
            return true
        }
        let range = prediction.range
        let replacement = prediction.replacement
        clear()
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: range, replacementString: replacement) else { return true }
        tv.textStorage?.replaceCharacters(in: range, with: replacement)
        tv.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
        tv.didChangeText()
        tv.breakUndoCoalescing()
        return true
    }

    /// Ask now, without waiting for the pause.
    func trigger() {
        task?.cancel()
        task = Task { [weak self] in await self?.run(force: true) }
    }

    func clear() {
        task?.cancel()
        task = nil
        guard prediction != nil else { return }
        if let tv = textView, let lm = tv.layoutManager, let range = prediction?.range,
           NSMaxRange(range) <= (tv.string as NSString).length {
            lm.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: range)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        prediction = nil
        previewLabel?.removeFromSuperview()
        previewLabel = nil
        gutter?.nextEditLine = nil
    }

    // MARK: - Requesting

    private func schedule() {
        task?.cancel()
        guard isEnabled() else { return }
        let ms = delayMs
        task = Task { [weak self] in
            // ContinuousClock, not Task.sleep(for:) — Swift 6.2 toolchain crash.
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(ms)))
            guard !Task.isCancelled else { return }
            await self?.run(force: false)
        }
    }

    private func run(force: Bool) async {
        guard isEnabled(), let tv = textView, tv.selectedRanges.count == 1 else { return }
        if !force, isGhostVisible() { return }
        closeBurst(keepOpen: true)
        guard let last = history.last else { return }

        let ns = tv.string as NSString
        let cursor = tv.selectedRange().location
        let cursorLine = Self.lineNumber(at: cursor, in: ns)
        let lines = (tv.string).components(separatedBy: "\n")
        let first = max(1, last.line - Self.excerptRadius)
        let lastLine = min(lines.count, last.line + Self.excerptRadius)
        guard first <= lastLine else { return }
        let excerpt = lines[(first - 1)..<lastLine].joined(separator: "\n")
        let query = NextEditQuery(excerpt: excerpt, excerptStartLine: first, cursorLine: cursorLine, edits: history)

        let version = docVersion
        guard let candidate = await requestCandidate(query),
              !Task.isCancelled, version == docVersion, let tv = textView
        else { return }

        let buffer = tv.string as NSString
        let excerptStart = Self.location(ofLine: first, in: buffer)
        let excerptEnd = Self.location(ofLine: lastLine + 1, in: buffer)
        let window = NSRange(location: excerptStart, length: max(0, excerptEnd - excerptStart))
        guard let range = Self.locate(candidate, in: buffer, within: window, cursor: tv.selectedRange().location) else { return }
        show(NextEditPrediction(range: range, original: candidate.original, replacement: candidate.replacement))
    }

    // MARK: - Display

    private func show(_ prediction: NextEditPrediction) {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        self.prediction = prediction
        lm.addTemporaryAttributes([
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .backgroundColor: NSColor.systemRed.withAlphaComponent(0.14),
        ], forCharacterRange: prediction.range)
        gutter?.nextEditLine = Self.lineNumber(at: prediction.range.location, in: tv.string as NSString)
        layoutPreview(header: "⇥ Tab to jump · Esc to dismiss")
    }

    /// A box under the target's last line with the replacement text.
    private func layoutPreview(header: String) {
        guard let tv = textView, let lm = tv.layoutManager, let prediction else { return }
        let ns = tv.string as NSString
        guard NSMaxRange(prediction.range) <= ns.length else { return }
        let lastChar = max(prediction.range.location, NSMaxRange(prediction.range) - 1)
        lm.ensureLayout(forCharacterRange: NSRange(location: lastChar, length: min(1, ns.length - lastChar)))
        let glyph = lm.glyphIndexForCharacter(at: min(lastChar, max(ns.length - 1, 0)))
        let lineRect = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = tv.textContainerOrigin

        let font = tv.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = NSMutableAttributedString(string: header + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: max(font.pointSize - 2, 9)),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        text.append(NSAttributedString(string: prediction.replacement, attributes: [
            .font: font,
            .foregroundColor: NSColor.systemGreen,
        ]))

        let label = previewLabel ?? {
            let field = NSTextField(labelWithString: "")
            field.isEditable = false
            field.isSelectable = false
            field.drawsBackground = true
            field.isBordered = true
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byClipping
            field.cell?.wraps = false
            tv.addSubview(field)
            previewLabel = field
            return field
        }()
        label.backgroundColor = tv.backgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? tv.backgroundColor
        label.attributedStringValue = text
        let size = text.size()
        let leftX = lineRect.minX + origin.x
        label.frame = CGRect(
            x: leftX,
            y: lineRect.maxY + origin.y + 2,
            width: min(ceil(size.width) + 12, max(tv.visibleRect.maxX - leftX - 8, 120)),
            height: ceil(size.height) + 6
        )
    }

    private var gutter: GutterView? {
        textView?.enclosingScrollView?.verticalRulerView as? GutterView
    }

    // MARK: - History

    /// Moves the current burst into history. `keepOpen` keeps it as the
    /// open burst too (more typing on the same line extends it).
    private func closeBurst(keepOpen: Bool = false) {
        guard let current = burst, let tv = textView else { return }
        let ns = tv.string as NSString
        let after = Self.lineText(at: min(current.location, ns.length), in: ns)
        if after != current.before {
            let edit = RecentEdit(line: Self.lineNumber(at: min(current.location, ns.length), in: ns),
                                  before: current.before, after: after)
            history.removeAll { $0.line == edit.line && $0.before == edit.before }
            history.append(edit)
            if history.count > Self.historyLimit { history.removeFirst() }
        }
        if !keepOpen { burst = nil }
    }

    // MARK: - Pure helpers

    /// Where `candidate.original` applies: its only occurrence inside
    /// `window`, and not one the caret sits inside (that's typing, not a
    /// next edit). `nil` otherwise — a guess is worse than no suggestion.
    nonisolated static func locate(_ candidate: NextEditCandidate, in buffer: NSString, within window: NSRange, cursor: Int) -> NSRange? {
        let clamped = NSIntersectionRange(window, NSRange(location: 0, length: buffer.length))
        guard clamped.length > 0, !candidate.original.isEmpty else { return nil }
        let first = buffer.range(of: candidate.original, options: [], range: clamped)
        guard first.location != NSNotFound else { return nil }
        let afterFirst = NSMaxRange(first)
        if afterFirst < NSMaxRange(clamped) {
            let second = buffer.range(of: candidate.original, options: [],
                                      range: NSRange(location: afterFirst, length: NSMaxRange(clamped) - afterFirst))
            if second.location != NSNotFound { return nil }
        }
        if cursor > first.location, cursor < NSMaxRange(first) { return nil }
        return first
    }

    nonisolated static func lineNumber(at location: Int, in ns: NSString) -> Int {
        var line = 1
        var i = 0
        let end = min(location, ns.length)
        while i < end {
            if ns.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        return line
    }

    nonisolated static func lineText(at location: Int, in ns: NSString) -> String {
        let range = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        return ns.substring(with: range).trimmingCharacters(in: .newlines)
    }

    /// UTF-16 location where 1-based `line` starts (the end for lines past it).
    nonisolated static func location(ofLine line: Int, in ns: NSString) -> Int {
        guard line > 1 else { return 0 }
        var current = 1
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 0x0A {
                current += 1
                if current == line { return i + 1 }
            }
            i += 1
        }
        return ns.length
    }
}
