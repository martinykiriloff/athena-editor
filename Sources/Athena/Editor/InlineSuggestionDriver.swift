// InlineSuggestionDriver.swift
// Athena — the ghost-text state machine: when to ask, when a reply is stale,
// type-through, partial accept, alternatives, and remembered dismissals.
// Swift 6, strict concurrency.

@preconcurrency import AppKit

// MARK: - InlineSuggestionDriver

/// Owns one editor's ghost text. `EditorView.Coordinator` forwards text,
/// selection, mouse and key events; everything about when a suggestion is
/// requested, shown, advanced, or thrown away lives here.
///
/// Every reply is checked against the buffer version and caret it was asked
/// for before it's drawn, so a reply that lands after the user moved or
/// typed is dropped instead of being shown (and accepted) in the wrong place.
@MainActor
final class InlineSuggestionDriver {

    // MARK: Wiring

    let ghost = GhostTextController()
    weak var textView: NSTextView?
    /// Streams events for one query; finishing the stream ends the request.
    var requestStream: @MainActor (InlineCompletionQuery) -> AsyncStream<InlineCompletionEvent> = { _ in
        AsyncStream { $0.finish() }
    }
    var isPopupVisible: () -> Bool = { false }
    var debounceMs: Int = 700
    /// Session counters (Settings shows shown vs accepted).
    var onShown: () -> Void = {}
    var onAccepted: () -> Void = {}

    // MARK: State

    private var task: Task<Void, Never>?
    private var alternativesTask: Task<Void, Never>?
    /// Bumped on every text change; a reply for an older version is stale.
    private(set) var docVersion = 0
    private var pendingEdit: (range: NSRange, replacement: String)?
    /// Caret the pending debounce was scheduled for.
    private var scheduledCursor: Int?
    /// Positions the user dismissed with Escape — the same suggestion
    /// shouldn't pop straight back. Most recent last; bounded.
    private var dismissedKeys: [String] = []
    private var alternatives: [String] = []
    private var alternativeIndex = 0
    private var currentMode: InlineCompletionMode = .endOfLine

    private static let dismissedLimit = 32

    // MARK: - Text and selection events

    /// From `textView(_:shouldChangeTextIn:replacementString:)`.
    func willChangeText(range: NSRange, replacement: String?) {
        pendingEdit = replacement.map { (range, $0) }
    }

    /// From `textDidChange`. Returns `true` when the edit typed through the
    /// visible suggestion (it was kept and advanced) — the caller then skips
    /// the completion popup so the two don't compete for Tab.
    @discardableResult
    func textDidChange() -> Bool {
        docVersion += 1
        let edit = pendingEdit
        pendingEdit = nil

        if ghost.hasSuggestion, let edit, let tv = textView,
           edit.range.length == 0, edit.range.location == ghost.anchor,
           tv.selectedRanges.count == 1,
           ghost.advance(typed: edit.replacement) {
            // Whatever was in flight described the old caret.
            cancelRequests()
            alternatives = []
            return true
        }

        ghost.dismiss()
        cancelRequests()
        alternatives = []
        schedule()
        return false
    }

    /// From `textViewDidChangeSelection`. Deferred one turn of the main
    /// queue so a type-through's `textDidChange` (which moves the anchor)
    /// has run first — AppKit may post the selection change mid-edit.
    func selectionDidChange() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.validateCaret() }
        }
    }

    func mouseDown() {
        dismiss()
    }

    // MARK: - Keys

    /// Tab, Escape, ⌘→ (next word), ⌥] / ⌥[ (alternatives). Returns `true`
    /// when consumed. Only acts while a suggestion is visible, so the same
    /// keys keep their normal meaning otherwise.
    func handleKey(_ event: NSEvent) -> Bool {
        guard ghost.hasSuggestion, let tv = textView else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, mods) {
        case (48, []):            // Tab — accept all
            let accepted = ghost.accept(in: tv)
            if accepted { onAccepted() }
            return accepted
        case (53, _):             // Escape — dismiss, and remember the spot
            rememberDismissal()
            dismiss()
            return true
        case (124, [.command]):   // ⌘→ — accept the next word
            return acceptChunk(GhostTextPolicy.nextWordChunk(of: ghost.suggestion), in: tv)
        case (30, [.option]):     // ⌥] — next alternative
            cycle(forward: true)
            return true
        case (33, [.option]):     // ⌥[ — previous alternative
            cycle(forward: false)
            return true
        default:
            return false
        }
    }

    /// Editor command: accept up to and including the next line break.
    func acceptNextLine() {
        guard ghost.hasSuggestion, let tv = textView else { return }
        _ = acceptChunk(GhostTextPolicy.nextLineChunk(of: ghost.suggestion), in: tv)
    }

    /// ⌥\ — ask now, at this caret, even mid-identifier.
    func triggerManually() {
        cancelRequests()
        ghost.dismiss()
        task = Task { [weak self] in
            await self?.run(manual: true)
        }
    }

    func dismiss() {
        cancelRequests()
        alternatives = []
        ghost.dismiss()
    }

    // MARK: - Requesting

    private func schedule() {
        guard let tv = textView else { return }
        scheduledCursor = tv.selectedRange().location
        let ms = debounceMs
        task = Task { [weak self] in
            // ContinuousClock, not Task.sleep(for:) — Swift 6.2 toolchain crash.
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(ms)))
            guard !Task.isCancelled else { return }
            await self?.run(manual: false)
        }
    }

    private func cancelRequests() {
        task?.cancel()
        task = nil
        alternativesTask?.cancel()
        alternativesTask = nil
        scheduledCursor = nil
    }

    private func run(manual: Bool) async {
        guard let tv = textView, tv.selectedRanges.count == 1 else { return }
        let selection = tv.selectedRange()
        guard selection.length == 0 else { return }
        let ns = tv.string as NSString
        let cursor = selection.location
        guard let mode = GhostTextPolicy.mode(
            text: ns, cursor: cursor, isPopupVisible: isPopupVisible(), manual: manual
        ) else { return }

        let prefix = ns.substring(to: cursor)
        let suffix = ns.substring(from: cursor)
        let key = Self.positionKey(prefix: prefix, suffix: suffix)
        if !manual, dismissedKeys.contains(key) { return }

        let version = docVersion
        let restOfLine = Self.restOfLine(in: ns, from: cursor)
        let query = InlineCompletionQuery(prefix: prefix, suffix: suffix, mode: mode)
        var counted = false

        for await event in requestStream(query) {
            guard isCurrent(version: version, cursor: cursor) else { return }
            let raw: String?
            switch event {
            case .text(let t):     raw = t
            case .finished(let t): raw = t
            case .failed, .rateLimited: continue
            }
            guard let raw,
                  let fitted = GhostTextPolicy.fit(raw, mode: mode, restOfLine: restOfLine, suffix: suffix),
                  GhostTextPolicy.isSubstantial(fitted, manual: manual)
            else { continue }

            currentMode = mode
            if ghost.hasSuggestion, ghost.anchor == cursor {
                ghost.replace(with: fitted, badge: nil)
            } else {
                ghost.show(text: fitted, at: cursor, mode: mode, font: font(of: tv), in: tv)
            }
            if case .finished = event { alternatives = [fitted]; alternativeIndex = 0 }
            if !counted { counted = true; onShown() }
        }
    }

    /// Whether a reply for (`version`, `cursor`) may still be drawn.
    private func isCurrent(version: Int, cursor: Int) -> Bool {
        guard !Task.isCancelled, version == docVersion, let tv = textView,
              tv.selectedRanges.count == 1,
              tv.selectedRange() == NSRange(location: cursor, length: 0),
              !isPopupVisible()
        else { return false }
        return true
    }

    // MARK: - Alternatives (⌥] / ⌥[)

    private func cycle(forward: Bool) {
        guard let tv = textView else { return }
        if alternatives.count > 1 {
            step(forward: forward, in: tv)
            return
        }
        guard alternativesTask == nil else { return }
        let current = ghost.suggestion
        alternatives = [current]
        alternativeIndex = 0
        ghost.replace(with: current, badge: "1/…")

        let ns = tv.string as NSString
        let anchor = ghost.anchor
        let mode = currentMode
        let prefix = ns.substring(to: anchor)
        let suffix = ns.substring(from: anchor)
        let restOfLine = Self.restOfLine(in: ns, from: anchor)
        let version = docVersion
        // Both requests start when their streams are created, so they run
        // side by side even though they're read one after the other.
        let streams = (1...2).map {
            requestStream(InlineCompletionQuery(prefix: prefix, suffix: suffix, mode: mode, variant: $0))
        }

        alternativesTask = Task { [weak self] in
            var found: [String] = []
            for stream in streams {
                var final: String?
                for await event in stream {
                    if case .finished(let t) = event { final = t }
                }
                if let final,
                   let fitted = GhostTextPolicy.fit(final, mode: mode, restOfLine: restOfLine, suffix: suffix) {
                    found.append(fitted)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.alternativesTask = nil
            guard self.ghost.hasSuggestion, self.docVersion == version, self.ghost.anchor == anchor else { return }
            for candidate in found where !self.alternatives.contains(candidate) {
                self.alternatives.append(candidate)
            }
            if self.alternatives.count > 1, let tv = self.textView {
                self.step(forward: forward, in: tv)
            } else {
                self.ghost.replace(with: self.ghost.suggestion, badge: "1/1")
            }
        }
    }

    private func step(forward: Bool, in tv: NSTextView) {
        let n = alternatives.count
        alternativeIndex = (alternativeIndex + (forward ? 1 : n - 1)) % n
        ghost.replace(with: alternatives[alternativeIndex], badge: "\(alternativeIndex + 1)/\(n)")
    }

    // MARK: - Helpers

    private func acceptChunk(_ chunk: String, in tv: NSTextView) -> Bool {
        guard !chunk.isEmpty else { return false }
        let wholeSuggestion = chunk == ghost.suggestion
        let ok = ghost.acceptChunk(chunk, in: tv)
        if ok, wholeSuggestion { onAccepted() }
        return ok
    }

    private func validateCaret() {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        if ghost.hasSuggestion,
           selection.length != 0 || selection.location != ghost.anchor || tv.selectedRanges.count > 1 {
            dismiss()
            return
        }
        if let scheduled = scheduledCursor, scheduled != selection.location || selection.length != 0 {
            cancelRequests()
        }
    }

    private func rememberDismissal() {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let anchor = min(ghost.anchor, ns.length)
        let key = Self.positionKey(prefix: ns.substring(to: anchor), suffix: ns.substring(from: anchor))
        dismissedKeys.removeAll { $0 == key }
        dismissedKeys.append(key)
        if dismissedKeys.count > Self.dismissedLimit { dismissedKeys.removeFirst() }
    }

    private func font(of tv: NSTextView) -> NSFont {
        tv.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    /// Identifies a caret position by its surroundings, so the same spot is
    /// recognised after unrelated edits elsewhere shift its offset.
    nonisolated static func positionKey(prefix: String, suffix: String) -> String {
        String(prefix.suffix(300)) + "\u{0}" + String(suffix.prefix(120))
    }

    nonisolated static func restOfLine(in ns: NSString, from location: Int) -> String {
        guard location <= ns.length else { return "" }
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        var end = NSMaxRange(line)
        while end > location, ns.character(at: end - 1) == 0x0A || ns.character(at: end - 1) == 0x0D { end -= 1 }
        return end > location ? ns.substring(with: NSRange(location: location, length: end - location)) : ""
    }
}
