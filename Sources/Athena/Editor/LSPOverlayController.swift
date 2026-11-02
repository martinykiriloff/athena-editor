// LSPOverlayController.swift
// Athena — keeps LSP inlay hints, code lenses, semantic-token colours and linked editing
// in sync with one text view, without touching its text storage attributes.
// Swift 6, strict concurrency.

@preconcurrency import AppKit
import Observation

@MainActor
final class LSPOverlayController: NSObject {

    // MARK: State

    private weak var textView: NSTextView?
    private let appState: AppState
    private let fileURL: () -> URL?
    private let theme: () -> EditorTheme

    private var lenses: [CodeLens] = []
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var retries = 0

    private var linked: LinkedEditingRanges?
    private var linkedRanges: [NSRange] = []
    private var linkTask: Task<Void, Never>?
    private var pendingEdits: [(edited: NSRange, delta: Int)] = []
    private var isMirroring = false

    // MARK: Lifecycle

    init(textView: NSTextView, appState: AppState, fileURL: @escaping () -> URL?, theme: @escaping () -> EditorTheme) {
        self.textView = textView
        self.appState = appState
        self.fileURL = fileURL
        self.theme = theme
        super.init()
        if let storage = textView.textStorage {
            NotificationCenter.default.addObserver(
                self, selector: #selector(storageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: textView)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        textView.addGestureRecognizer(click)
        observeSettings()
        scheduleRefresh(after: .milliseconds(1200))
    }

    private func observeSettings() {
        withObservationTracking {
            _ = appState.editorInlayHints
            _ = appState.editorSemanticTokens
            _ = appState.editorCodeLens
            _ = appState.editorLinkedEditing
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.retries = 0
                self.scheduleRefresh(after: .milliseconds(50))
                self.observeSettings()
            }
        }
    }

    // MARK: Notifications

    @objc private func storageDidProcessEditing(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        if linked != nil, !isMirroring {
            pendingEdits.append((storage.editedRange, storage.changeInLength))
            Task { @MainActor in self.mirrorPendingEdits() }
        }
        retries = 0
        scheduleRefresh(after: .milliseconds(500))
    }

    @objc private func selectionDidChange(_ note: Notification) {
        guard !isMirroring else { return }
        linkTask?.cancel()
        guard appState.editorLinkedEditing, let tv = textView, tv.selectedRange().length == 0, let url = fileURL() else {
            clearLinked()
            return
        }
        // Still inside the known linked ranges: keep them.
        let caret = tv.selectedRange().location
        if linkedRanges.contains(where: { caret >= $0.location && caret <= NSMaxRange($0) }) { return }
        clearLinked()
        let text = tv.string as NSString
        let starts = LSPPositions.lineStarts(text)
        guard let line = starts.lastIndex(where: { $0 <= caret }) else { return }
        let character = caret - starts[line]
        let length = text.length
        linkTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(150)))
            guard !Task.isCancelled, let self else { return }
            let result = await self.appState.lspManager.linkedEditingRanges(fileURL: url, line: line, character: character)
            guard !Task.isCancelled, let tv = self.textView, (tv.string as NSString).length == length,
                  let result else { return }
            let t = tv.string as NSString
            let s = LSPPositions.lineStarts(t)
            let ranges = result.ranges.compactMap { LSPPositions.range($0, text: t, lineStarts: s) }
            guard ranges.count == result.ranges.count else { return }
            self.linked = result
            self.linkedRanges = ranges
        }
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let tv = textView, let lm = tv.layoutManager as? AthenaLayoutManager,
              let url = fileURL() else { return }
        let location = recognizer.location(in: tv)
        let origin = tv.textContainerOrigin
        let point = NSPoint(x: location.x - origin.x, y: location.y - origin.y)
        guard let id = lm.lensID(at: point), let lens = lenses.first(where: { $0.id == id }) else { return }
        Task { await appState.activateCodeLens(lens, fileURL: url) }
    }

    // MARK: Linked editing

    private func clearLinked() {
        linked = nil
        linkedRanges = []
        pendingEdits = []
    }

    private func mirrorPendingEdits() {
        guard let tv = textView, let storage = tv.textStorage, let current = linked else { pendingEdits = []; return }
        let edits = pendingEdits
        pendingEdits = []
        guard edits.count == 1, let edit = edits.first,
              let plan = LinkedEditingMirror.plan(ranges: linkedRanges, edited: edit.edited, delta: edit.delta,
                                                   postText: storage.string as NSString, wordPattern: current.wordPattern)
        else { clearLinked(); return }

        let selection = tv.selectedRange()
        var caretShift = 0
        isMirroring = true
        for item in plan.edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard tv.shouldChangeText(in: item.range, replacementString: item.text) else { continue }
            storage.replaceCharacters(in: item.range, with: item.text)
            tv.didChangeText()
            if item.range.location < selection.location { caretShift += (item.text as NSString).length - item.range.length }
        }
        tv.setSelectedRange(NSRange(location: max(selection.location + caretShift, 0), length: 0))
        isMirroring = false
        linkedRanges = plan.finalRanges
    }

    // MARK: Refresh

    private func scheduleRefresh(after delay: Duration) {
        refreshTask?.cancel()
        generation &+= 1
        let gen = generation
        refreshTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now.advanced(by: delay))
            guard !Task.isCancelled, let self else { return }
            await self.refresh(generation: gen)
        }
    }

    private func refresh(generation gen: Int) async {
        guard let tv = textView, let lm = tv.layoutManager as? AthenaLayoutManager else { return }
        let wantsHints = appState.editorInlayHints
        let wantsTokens = appState.editorSemanticTokens
        let wantsLens = appState.editorCodeLens
        guard let url = fileURL(), wantsHints || wantsTokens || wantsLens else {
            lenses = []
            lm.setLineAnnotations([:])
            lm.setSemanticColors([])
            return
        }
        let length = (tv.string as NSString).length
        let lineCount = LSPPositions.lineStarts(tv.string as NSString).count
        let lsp = appState.lspManager

        async let hints = wantsHints ? lsp.inlayHints(fileURL: url, lineCount: lineCount) : []
        async let tokens = wantsTokens ? lsp.semanticTokens(fileURL: url) : []
        async let fetchedLenses = wantsLens ? lsp.codeLenses(fileURL: url) : []
        let (h, t, l) = await (hints, tokens, fetchedLenses)

        // Text changed while waiting: positions are stale, a newer refresh is queued.
        guard gen == generation, let tv = textView, (tv.string as NSString).length == length,
              let lm = tv.layoutManager as? AthenaLayoutManager else { return }
        let text = tv.string as NSString
        let starts = LSPPositions.lineStarts(text)

        lenses = l
        var annotations: [Int: [AthenaLayoutManager.LineAnnotation]] = [:]
        for lens in l {
            guard let title = lens.title, !title.isEmpty else { continue }
            annotations[lens.line, default: []].append(.init(text: title, lensID: lens.id))
        }
        for (line, hintText) in InlayHintFormatter.lineTexts(hints: h, text: text, lineStarts: starts) {
            annotations[line, default: []].append(.init(text: hintText, lensID: nil))
        }
        lm.annotationColor = theme().comment.withAlphaComponent(0.85)
        lm.setLineAnnotations(annotations)

        let palette = theme()
        let colored = SemanticTokenStyle.ranges(for: t, text: text, lineStarts: starts).map { item -> (range: NSRange, color: NSColor) in
            let color: NSColor
            switch item.category {
            case .type: color = palette.type
            case .function: color = palette.function
            case .keyword: color = palette.keyword
            case .string: color = palette.string
            case .number: color = palette.number
            case .comment: color = palette.comment
            case .annotation: color = palette.annotation
            }
            return (item.range, color)
        }
        lm.setSemanticColors(wantsTokens ? colored : [])

        // The server may still be starting; a few bounded retries.
        let gotNothing = h.isEmpty && t.isEmpty && l.isEmpty
        if gotNothing, retries < 3 {
            retries += 1
            scheduleRefresh(after: .seconds(3))
        }
    }
}
