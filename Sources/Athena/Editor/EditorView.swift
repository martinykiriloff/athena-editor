// EditorView.swift
// Athena — NSViewRepresentable wrapping NSTextView for the code editor pane.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

// MARK: - EditorView

struct EditorView: NSViewRepresentable {

    // MARK: Bindings & callbacks

    @Binding var content: String
    var language: Language
    var theme: EditorTheme = .darcula
    var fontSize:       CGFloat = 14
    var fontFamily:     String  = "JetBrains Mono"
    var fontLigatures:  Bool    = true
    var lineHeight:     CGFloat = 1.5
    var wordWrap:       Bool    = false
    var renderWhitespace: Bool  = true
    var tabSize:        Int     = 4
    var insertSpaces:   Bool    = true
    var autoIndent:     Bool    = true
    var blameInfo: [Int: BlameLine] = [:]
    /// Live LSP diagnostics for the file being edited (`AppState.diagnostics[fileURL]`),
    /// used to paint squiggle underlines and feed the gutter's error/warning
    /// dots and the hover tooltip's "show the diagnostic message" priority path.
    var diagnostics: [Diagnostic] = []
    /// The URL of the file being edited — used for import path resolution.
    var fileURL: URL? = nil
    var onCursorMove: (Int, Int) -> Void = { _, _ in }
    var onContentChange: (String) -> Void = { _ in }
    /// Called whenever the scroll position changes. (fraction 0‥1, visible ratio 0‥1)
    var onScrollChange: (Double, Double) -> Void = { _, _ in }
    /// Called when the user clicks on a quoted import path string.
    /// First argument is the raw path (e.g. `"./configs"`), second is the current file URL.
    var onImportClick: (String, URL?) -> Void = { _, _ in }
    /// Requests `textDocument/definition` for the given 1-based line/column —
    /// the Cmd+Click fallback used when the click isn't on a recognized
    /// import path. Returns `nil` when there's no server running or result.
    var onRequestDefinition: (Int, Int) async -> DefinitionLocation? = { _, _ in nil }
    /// Opens `url` in the editor (e.g. the target of a cross-file "Go to
    /// Definition" jump) so this view's `fileURL`/`content` bindings update.
    var onOpenDefinitionFile: (URL) async -> Void = { _ in }
    /// Requests LSP hover text (markdown/plaintext, already flattened to a
    /// plain string) for the given 1-based line/column.
    var onRequestHover: (Int, Int) async -> String? = { _, _ in nil }
    /// Requests `textDocument/references` for the given 1-based line/column
    /// (⌥⇧F12, "Find All References") and hands the results off to
    /// `AppState` to populate the References panel.
    var onFindReferences: (Int, Int) async -> Void = { _, _ in }
    /// Requests `textDocument/rename` for the given 1-based line/column,
    /// renaming the symbol there to `newName` (F2, "Rename Symbol"), and
    /// applies the resulting workspace edit.
    var onRenameSymbol: (Int, Int, String) async -> Void = { _, _, _ in }
    /// A pending cross-view "jump to this location" request set by `AppState`
    /// (e.g. a References panel row click) — consumed once this file's
    /// content is the target's, then cleared via `onNavigationConsumed`.
    var pendingNavigationTarget: NavigationRequest? = nil
    /// Clears `pendingNavigationTarget` on `AppState` once consumed.
    var onNavigationConsumed: () -> Void = {}
    /// Set by the representable so external callers can scroll the editor.
    var scrollProxy: Binding<EditorScrollProxy?>? = nil
    /// Set by the representable so the SwiftUI find/replace bar can drive
    /// (and observe match state from) this editor's text view.
    var findReplaceProxy: Binding<FindReplaceController?>? = nil
    /// Breakpoints for the current file (1-based line numbers).
    var breakpoints: Set<Int> = []
    /// Current debug line to highlight (1-based, nil when not debugging).
    var debugLine: Int? = nil
    /// Called when the user clicks in the gutter to toggle a breakpoint.
    var onToggleBreakpoint: (Int) -> Void = { _ in }

    /// Returns merged completion items (LSP + Drizzle) for the given 1-based line/col.
    var onRequestCompletion: (Int, Int) async -> [CompletionItem] = { _, _ in [] }
    /// Returns an AI ghost-text suggestion given the text before and after the cursor.
    var onRequestGhostText: (String, String) async -> String? = { _, _ in nil }

    // MARK: NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        // Build the scrollable-text-view stack manually so we can use our
        // AthenaTextView subclass (which overrides mouseDown for Cmd+Click).
        let textStorage  = NSTextStorage()
        let layoutMgr    = NSLayoutManager()
        textStorage.addLayoutManager(layoutMgr)
        let inf = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: 0, height: inf))
        container.widthTracksTextView = true
        layoutMgr.addTextContainer(container)

        let textView = AthenaTextView(frame: .zero, textContainer: container)
        textView.minSize                  = NSSize(width: 0, height: 0)
        textView.maxSize                  = NSSize(width: inf, height: inf)
        textView.isVerticallyResizable    = true
        textView.isHorizontallyResizable  = false
        textView.autoresizingMask         = NSView.AutoresizingMask.width

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask      = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        scrollView.documentView          = textView

        // Install breakpoint / line-number gutter.
        let gutter = GutterView(scrollView: scrollView, orientation: .verticalRuler)
        gutter.clientView = textView
        gutter.breakpoints = breakpoints
        gutter.debugLine   = debugLine
        gutter.diagnostics = Self.gutterDiagnosticSeverities(from: diagnostics)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler  = true
        scrollView.rulersVisible     = true
        context.coordinator.gutterView = gutter
        let coordinator = context.coordinator
        gutter.onToggleBreakpoint = { [weak coordinator] line in
            coordinator?.parent.onToggleBreakpoint(line)
        }
        gutter.installObservers(textView: textView)

        configureTextView(textView, coordinator: context.coordinator)

        textView.string = content
        context.coordinator.applyHighlighting(to: textView)
        context.coordinator.currentDiagnostics = diagnostics
        context.coordinator.updateDiagnosticHighlights(in: textView)

        // Inline blame annotation label.
        let blameLabel = NSTextField(labelWithString: "")
        blameLabel.isEditable     = false
        blameLabel.isBordered     = false
        blameLabel.drawsBackground = false
        blameLabel.isSelectable   = false
        blameLabel.alphaValue     = 0
        textView.addSubview(blameLabel)
        context.coordinator.blameAnnotationLabel = blameLabel

        // AI ghost text overlay — positioned after cursor, scrolls with content.
        let ghostLabel = NSTextField(labelWithString: "")
        ghostLabel.isEditable      = false
        ghostLabel.isBordered      = false
        ghostLabel.drawsBackground = false
        ghostLabel.isSelectable    = false
        ghostLabel.alphaValue      = 0
        textView.addSubview(ghostLabel)
        context.coordinator.ghostController.install(label: ghostLabel)

        // Expose scroll view via proxy so the minimap can drive scrolling.
        let proxy = EditorScrollProxy()
        proxy.scrollView = scrollView
        scrollProxy?.wrappedValue = proxy
        context.coordinator.scrollProxy = proxy

        // Observe live scroll notifications to feed the minimap.
        context.coordinator.installScrollObserver(on: scrollView)

        // Expose the find/replace controller via proxy so the SwiftUI find
        // bar can drive this editor's text view, mirroring `scrollProxy` above.
        let findController = FindReplaceController()
        findController.textView = textView
        findReplaceProxy?.wrappedValue = findController
        context.coordinator.findReplaceController = findController

        // Let the keybinding system reach this editor (find, comment, indent…).
        context.coordinator.textView = textView
        context.coordinator.installCommandObserver()

        // Wire Cmd+Click: import paths resolve locally (fast, no round-trip);
        // anything else falls through to an LSP "Go to Definition" lookup.
        let coord = context.coordinator
        textView.onCmdClick = { [weak coord, weak textView] (charIdx: Int) in
            guard let coord, let tv = textView else { return }
            if let path = coord.importPath(from: tv.string, at: charIdx) {
                coord.parent.onImportClick(path, coord.parent.fileURL)
                return
            }
            coord.requestDefinition(at: charIdx)
        }

        // Option+Click adds an empty caret at the click point (multi-cursor).
        // Cmd+Click is already Go to Definition/import-nav (above), so this
        // deviates from VS Code's own Cmd+Click-for-multi-cursor convention
        // to avoid colliding with it — see plan.md item 11.
        textView.onOptionClick = { [weak coord, weak textView] (charIdx: Int) in
            guard let coord, let tv = textView else { return }
            coord.addCursor(at: charIdx, in: tv)
        }

        // Switch to the pointing-hand cursor while Cmd-hovering a clickable target.
        textView.isClickableTarget = { [weak coord, weak textView] (charIdx: Int) in
            guard let coord, let tv = textView else { return false }
            return coord.isCmdClickable(in: tv.string, at: charIdx)
        }

        // Hover tooltip: after a dwell (and only when Cmd isn't held), show
        // LSP hover info near the mouse; cancel/dismiss on move-away.
        textView.onHoverMove = { [weak coord] charIdx in
            coord?.scheduleHover(at: charIdx)
        }
        textView.onHoverExit = { [weak coord] in
            coord?.cancelHover()
        }

        // Wire key interception for completion popup and ghost text accept.
        textView.onKeyDown = { [weak coord] event in
            coord?.handleKeyDown(event) ?? false
        }

        // Wire bracket/quote auto-close, type-through, and wrap-selection.
        textView.onInsertText = { [weak coord] str in
            coord?.handleInsertText(str) ?? false
        }

        // Dismiss popup, ghost text, and hover tooltip on any click so they
        // don't block Cmd+Click.
        textView.onMouseDown = { [weak coord] in
            coord?.completionController.dismiss()
            coord?.ghostController.dismiss()
            coord?.cancelHover()
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let coord = context.coordinator
        coord.parent = self          // keep fileURL and callbacks fresh on every render
        coord.currentTabSize      = tabSize
        coord.currentInsertSpaces = insertSpaces
        coord.currentAutoIndent   = autoIndent
        let themeChanged = coord.currentTheme != theme
        let langChanged  = coord.currentLanguage != language
        let fontChanged  = coord.currentFontSize != fontSize
                        || coord.currentFontFamily != fontFamily
                        || coord.currentFontLigatures != fontLigatures
                        || coord.currentLineHeight != lineHeight
        let wrapChanged  = coord.currentWordWrap != wordWrap
        let wsChanged    = coord.currentRenderWhitespace != renderWhitespace

        if themeChanged {
            coord.currentTheme = theme
            applyTheme(theme, to: textView)
        }

        if fontChanged {
            coord.currentFontSize      = fontSize
            coord.currentFontFamily    = fontFamily
            coord.currentFontLigatures = fontLigatures
            coord.currentLineHeight    = lineHeight
        }

        if themeChanged || langChanged || fontChanged {
            coord.currentLanguage = language
            coord.highlighter = SyntaxHighlighter(
                language: language, theme: theme,
                fontSize: fontSize, fontFamily: fontFamily,
                fontLigatures: fontLigatures, lineHeight: lineHeight
            )
        }

        if wrapChanged {
            coord.currentWordWrap = wordWrap
            applyWordWrap(wordWrap, to: textView)
        }

        if wsChanged {
            coord.currentRenderWhitespace = renderWhitespace
            if let lm = textView.layoutManager as? AthenaLayoutManager {
                lm.showWhitespace = renderWhitespace
                textView.layoutManager?.invalidateDisplay(forCharacterRange:
                    NSRange(location: 0, length: (textView.string as NSString).length))
            }
        }

        if textView.string != content {
            textView.string = content
            coord.applyHighlighting(to: textView)
            coord.consumePendingDefinitionScroll()
            coord.cancelActiveSnippet()
        } else if themeChanged || fontChanged {
            coord.applyHighlighting(to: textView)
        }

        // A "Find All References" panel click (or other cross-view jump)
        // targeting this file — consume it once the content above matches.
        coord.consumePendingNavigation(
            pendingNavigationTarget, currentFileURL: fileURL, onConsumed: onNavigationConsumed
        )

        if coord.currentBlameInfo != blameInfo {
            coord.currentBlameInfo = blameInfo
            coord.updateBlameLabel(in: textView, fontSize: fontSize, fontFamily: fontFamily, theme: theme)
        }

        // Sync gutter breakpoints / debug line.
        if let gutter = coord.gutterView {
            if gutter.breakpoints != breakpoints || gutter.debugLine != debugLine {
                gutter.breakpoints = breakpoints
                gutter.debugLine   = debugLine
                gutter.needsDisplay = true
            }
        }

        // Fresh diagnostics from AppState (a new LSP `publishDiagnostics`
        // batch) — recompute squiggle underlines and the gutter's
        // error/warning dots. `Diagnostic.==` compares by content, not `id`,
        // so this only fires when something actually changed.
        if coord.currentDiagnostics != diagnostics {
            coord.currentDiagnostics = diagnostics
            coord.updateDiagnosticHighlights(in: textView)
            if let gutter = coord.gutterView {
                gutter.diagnostics = Self.gutterDiagnosticSeverities(from: diagnostics)
                gutter.needsDisplay = true
            }
        }
    }

    /// Reduces the full diagnostics list to one highest-severity entry per
    /// line, `.error`/`.warning` only — the subset `GutterView` draws a dot
    /// for (see its `diagnostics` doc comment for why `.information`/`.hint`
    /// are excluded).
    private static func gutterDiagnosticSeverities(from diagnostics: [Diagnostic]) -> [Int: DiagnosticSeverity] {
        var result: [Int: DiagnosticSeverity] = [:]
        for diagnostic in diagnostics {
            switch diagnostic.severity {
            case .error:
                result[diagnostic.line] = .error
            case .warning:
                if result[diagnostic.line] != .error {
                    result[diagnostic.line] = .warning
                }
            case .information, .hint:
                continue
            }
        }
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: Private configuration

    private func configureTextView(_ textView: NSTextView, coordinator: Coordinator) {
        textView.isEditable    = true
        textView.isRichText    = false
        textView.allowsUndo    = true
        textView.usesFontPanel = false

        textView.isAutomaticQuoteSubstitutionEnabled  = false
        textView.isAutomaticDashSubstitutionEnabled   = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled    = false
        textView.isAutomaticLinkDetectionEnabled      = false

        applyWordWrap(wordWrap, to: textView)
        applyTheme(theme, to: textView)
        installLayoutManager(theme: theme, in: textView)

        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = coordinator

        // Suppress the default blue-underline link styling so import paths
        // look like normal code. Cmd+Click still fires textView(_:clickedOnLink:at:).
        textView.linkTextAttributes = [:]
    }

    private func applyWordWrap(_ wrap: Bool, to textView: NSTextView) {
        if wrap {
            textView.isHorizontallyResizable          = false
            textView.autoresizingMask                 = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize =
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.isHorizontallyResizable          = false
            textView.autoresizingMask                 = [.width]
            textView.textContainer?.widthTracksTextView = true
        }
    }

    private func applyTheme(_ t: EditorTheme, to textView: NSTextView) {
        textView.backgroundColor = t.background
        textView.textColor       = t.foreground
        textView.insertionPointColor = t.cursor
        textView.selectedTextAttributes = [.backgroundColor: t.selection]
        if let lm = textView.layoutManager as? AthenaLayoutManager {
            lm.dotColor       = t.whitespace
            lm.showWhitespace = renderWhitespace
        }
    }

    private func installLayoutManager(theme: EditorTheme, in textView: NSTextView) {
        guard let textStorage = textView.textStorage,
              let textContainer = textView.textContainer,
              let oldLM = textView.layoutManager else { return }
        let lm = AthenaLayoutManager()
        lm.dotColor = theme.whitespace
        oldLM.removeTextContainer(at: 0)
        textStorage.removeLayoutManager(oldLM)
        lm.addTextContainer(textContainer)
        textStorage.addLayoutManager(lm)
    }
}

// MARK: - Coordinator

extension EditorView {

    /// Live state for a snippet that's "active" after a snippet-shaped
    /// completion was accepted: its ordered tab stops (absolute document
    /// `NSRange`s, kept in sync with edits by
    /// `Coordinator.textView(_:shouldChangeTextIn:replacementString:)`) plus
    /// which one the caret is currently sitting in. Tab advances
    /// `currentIndex`; landing on the last stop (`$0`) ends tracking.
    private struct ActiveSnippet {
        var stops: [SnippetTabStop]
        var currentIndex: Int

        var currentRange: NSRange { stops[currentIndex].range }
        var isOnFinalStop: Bool { currentIndex == stops.count - 1 }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: EditorView
        var highlighter: SyntaxHighlighter
        var currentLanguage: Language
        var currentTheme: EditorTheme
        var currentFontSize:      CGFloat = 14
        var currentFontFamily:    String  = "JetBrains Mono"
        var currentFontLigatures: Bool    = true
        var currentLineHeight:    CGFloat = 1.5
        var currentWordWrap:      Bool    = false
        var currentRenderWhitespace: Bool = true
        var currentTabSize:       Int     = 4
        var currentInsertSpaces:  Bool    = true
        var currentAutoIndent:    Bool    = true
        var scrollProxy: EditorScrollProxy?
        var findReplaceController: FindReplaceController?
        weak var textView: NSTextView?
        nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
        nonisolated(unsafe) private var commandObserver: NSObjectProtocol?
        // no mouseMonitor needed — using NSClickGestureRecognizer instead

        // Blame annotation
        var blameAnnotationLabel: NSTextField?
        var currentBlameInfo: [Int: BlameLine] = [:]

        // Gutter (line numbers + breakpoints)
        weak var gutterView: GutterView?

        // Bracket-pair match highlight — the temporary layout-manager ranges
        // currently painted, so the next selection change can clear exactly
        // those without touching unrelated attributes (e.g. find-match highlights).
        private var highlightedBracketRanges: [NSRange] = []

        // Diagnostic squiggle underlines — same temporary-layout-manager-attribute
        // mechanism as bracket-pair matching above (`highlightedDiagnosticRanges`
        // mirrors `highlightedBracketRanges`), and reapplied from the same
        // `textViewDidChangeSelection` hook for the same reason: `applyHighlighting`'s
        // per-keystroke `textStorage.setAttributedString` invalidates every
        // temporary attribute in the edited range, and NSTextView always moves
        // the selection when a character is typed, so that hook gets the
        // "reapply after every edit" behavior for free. `currentDiagnostics` is
        // the file's most recent `AppState.diagnostics` batch (kept in sync by
        // `EditorView.updateNSView`/`makeNSView`), also consulted by the hover
        // tooltip to prioritize a diagnostic's message over an LSP hover call.
        var currentDiagnostics: [Diagnostic] = []
        private var highlightedDiagnosticRanges: [NSRange] = []

        // Completion popup and ghost text
        let completionController = CompletionWindowController()
        let ghostController      = GhostTextController()
        @ObservationIgnored private var completionDebounce: Task<Void, Never>?
        @ObservationIgnored private var ghostDebounce:      Task<Void, Never>?

        // Snippet tab-stop tracking (plan.md item 16, "B5") — set when a
        // snippet-shaped completion (`$1`/`${1:placeholder}`/`$0`) is
        // accepted in `insertCompletion`; cleared on Escape, on landing on
        // the final stop, or when the selection moves outside the current
        // stop's range by any means other than our own `advanceSnippet`.
        private var activeSnippet: ActiveSnippet?

        // Hover tooltip
        let hoverController = HoverWindowController()
        @ObservationIgnored private var hoverDebounce: Task<Void, Never>?
        private var hoverPendingCharIndex: Int?

        // A cross-file "Go to Definition" jump in flight: the target this
        // view's `fileURL` must match before `updateNSView` can safely
        // scroll to it — the previous tab's content is still loaded into
        // this same, reused text view until `AppState.openFile` switches the
        // active tab and SwiftUI re-renders with the new file's content.
        private var pendingDefinitionScroll: DefinitionLocation?

        // The `id` of the last externally-driven navigation request consumed
        // via `consumePendingNavigation` (e.g. a References panel row
        // click) — guards against re-jumping/re-clearing on every
        // `updateNSView` call while that same request's asynchronous
        // `AppState` clear is still in flight. Keyed by request `id` (not
        // the `DefinitionLocation` itself) so clicking the *same* reference
        // twice — a new request, same location — still triggers a fresh jump.
        private var lastConsumedNavigationRequestId: UUID?

        init(_ parent: EditorView) {
            self.parent              = parent
            self.currentLanguage     = parent.language
            self.currentTheme        = parent.theme
            self.currentFontSize     = parent.fontSize
            self.currentFontFamily   = parent.fontFamily
            self.currentFontLigatures = parent.fontLigatures
            self.currentLineHeight   = parent.lineHeight
            self.currentWordWrap     = parent.wordWrap
            self.currentRenderWhitespace = parent.renderWhitespace
            self.currentTabSize      = parent.tabSize
            self.currentInsertSpaces = parent.insertSpaces
            self.currentAutoIndent   = parent.autoIndent
            self.highlighter = SyntaxHighlighter(
                language: parent.language, theme: parent.theme,
                fontSize: parent.fontSize, fontFamily: parent.fontFamily,
                fontLigatures: parent.fontLigatures, lineHeight: parent.lineHeight
            )
        }

        func installScrollObserver(on scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView,
                          let docView = scrollView.documentView else { return }
                    let contentH = docView.frame.height
                    let visibleH = scrollView.contentView.bounds.height
                    let offsetY  = scrollView.contentView.bounds.origin.y
                    let fraction = contentH > visibleH
                        ? Double(offsetY / (contentH - visibleH))
                        : 0
                    let visible  = contentH > 0
                        ? Double(visibleH / contentH)
                        : 1
                    self.parent.onScrollChange(
                        max(0, min(1, fraction)),
                        max(0, min(1, visible))
                    )
                }
            }
        }

        deinit {
            if let obs = scrollObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = commandObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        // MARK: Editor commands (find / go-to-line / comment / indent)

        func installCommandObserver() {
            commandObserver = NotificationCenter.default.addObserver(
                forName: .athenaEditorCommand,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let command = note.object as? EditorCommand else { return }
                MainActor.assumeIsolated {
                    self?.handle(command)
                }
            }
        }

        // MARK: Import click — wired via AthenaTextView.onCmdClick in makeNSView

        /// Returns the last quoted string on the import/require line that contains
        /// `charIndex`. Works when clicked anywhere on the line, not just on the path.
        func importPath(from text: String, at charIndex: Int) -> String? {
            let ns = text as NSString
            guard charIndex < ns.length else { return nil }

            let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
            let line      = ns.substring(with: lineRange)

            let keywords  = ["import ", "require(", " from ", "@import", "#include", "export "]
            guard keywords.contains(where: { line.contains($0) }) else { return nil }

            // Collect all quoted strings on the line; return the last one.
            // For `import X from './path'` the path is always the last quoted token.
            let lineStart = lineRange.location
            let lineEnd   = NSMaxRange(lineRange)
            var i         = lineStart
            var lastPath: String?

            while i < lineEnd {
                let c = ns.character(at: i)
                if c == 34 || c == 39 || c == 96 {     // " ' `
                    let openQuote = c
                    let openPos   = i + 1
                    i += 1
                    while i < lineEnd {
                        if ns.character(at: i) == openQuote {
                            let path = ns.substring(with: NSRange(location: openPos, length: i - openPos))
                            if !path.isEmpty { lastPath = path }
                            i += 1
                            break
                        }
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
            return lastPath
        }

        /// Whether the character at `charIndex` is a Cmd-clickable navigation
        /// target: anywhere on an import line, or any code identifier (so
        /// methods/functions also show the pointing-hand cursor).
        func isCmdClickable(in text: String, at charIndex: Int) -> Bool {
            if importPath(from: text, at: charIndex) != nil { return true }
            let ns = text as NSString
            guard charIndex >= 0, charIndex < ns.length else { return false }
            return isIdentifierChar(ns.character(at: charIndex))
        }

        // MARK: - Go to Definition — LSP fallback when Cmd+Click isn't on an import path

        /// Looks up `textDocument/definition` at `charIndex` and navigates to
        /// the result. Called from `AthenaTextView.onCmdClick` (wired in
        /// `makeNSView`) only after `importPath(from:at:)` finds nothing —
        /// import-path resolution stays the fast, no-round-trip first check.
        func requestDefinition(at charIndex: Int) {
            guard let tv = textView else { return }
            let (line, col) = position(in: tv.string, at: charIndex)
            Task { [weak self] in
                guard let self, let target = await self.parent.onRequestDefinition(line, col) else { return }
                self.navigate(to: target)
            }
        }

        /// Same-file targets scroll immediately; cross-file targets ask
        /// `AppState` (via `onOpenDefinitionFile`) to open the file first —
        /// `consumePendingDefinitionScroll` finishes the jump once that
        /// file's content lands in this same, reused text view.
        private func navigate(to target: DefinitionLocation) {
            if target.fileURL.path == parent.fileURL?.path {
                scrollProxy?.jumpTo(line: target.line, column: target.character)
                return
            }
            pendingDefinitionScroll = target
            Task { [weak self] in
                await self?.parent.onOpenDefinitionFile(target.fileURL)
            }
        }

        /// Called by `updateNSView` right after it loads a newly-activated
        /// tab's content into the text view — completes a cross-file
        /// "Go to Definition" jump if the loaded file is the one it was
        /// waiting on.
        func consumePendingDefinitionScroll() {
            guard let target = pendingDefinitionScroll, target.fileURL.path == parent.fileURL?.path else { return }
            pendingDefinitionScroll = nil
            scrollProxy?.jumpTo(line: target.line, column: target.character)
        }

        /// Consumes an externally-set "jump to location" request — e.g. a
        /// "Find All References" panel row click, routed here via
        /// `AppState.pendingNavigationTarget` since that click originates
        /// outside this view's own hierarchy (unlike Cmd+Click, which starts
        /// inside this same Coordinator) — once this file's content is the
        /// request's target file. Idempotent *per request* (keyed by
        /// `request.id`, not the location it points at): a burst of
        /// `updateNSView` calls before `onConsumed`'s asynchronous `AppState`
        /// clear lands won't re-jump or double-clear for the *same* request,
        /// but a fresh request to the exact same location (e.g. clicking the
        /// same reference twice) still gets a new `id` and so still jumps —
        /// comparing by location alone would wrongly swallow that repeat
        /// click. Clearing happens on a later run-loop turn
        /// (`Task { onConsumed() }`) rather than synchronously here, since
        /// this runs from within `updateNSView` itself — mutating
        /// `@Observable` `AppState` state synchronously mid view-update is
        /// undefined behavior in SwiftUI.
        func consumePendingNavigation(
            _ request: NavigationRequest?,
            currentFileURL: URL?,
            onConsumed: @escaping () -> Void
        ) {
            guard let request, request.location.fileURL.path == currentFileURL?.path,
                  request.id != lastConsumedNavigationRequestId
            else { return }
            lastConsumedNavigationRequestId = request.id
            scrollProxy?.jumpTo(line: request.location.line, column: request.location.character)
            Task { onConsumed() }
        }

        // MARK: - Hover tooltip

        /// Schedules a hover lookup after a short dwell (matching the
        /// debounce style already used for ghost text / completion). Ignores
        /// repeat calls for the same character, and cancels/hides an
        /// in-flight or visible tooltip when the hovered character changes
        /// so the tooltip tracks the token under the mouse.
        func scheduleHover(at charIndex: Int) {
            guard hoverPendingCharIndex != charIndex else { return }
            hoverDebounce?.cancel()
            hoverController.dismiss()
            hoverPendingCharIndex = charIndex
            hoverDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)  // 500 ms
                guard !Task.isCancelled, let self else { return }
                await self.triggerHover(at: charIndex)
            }
        }

        /// Cancels any pending hover lookup and hides the tooltip — called
        /// on mouse-move-away, Cmd being held (navigate mode), any click, or
        /// any keystroke (see `handleKeyDown`/`textDidChange` below).
        func cancelHover() {
            hoverDebounce?.cancel()
            hoverDebounce = nil
            hoverPendingCharIndex = nil
            hoverController.dismiss()
        }

        private func triggerHover(at charIndex: Int) async {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            guard charIndex >= 0, charIndex < ns.length else { return }

            // A diagnostic squiggle at this position is a cheap local array
            // lookup — check it first and prioritize it over an LSP hover
            // round-trip (plan.md item 15, step 3).
            if let diag = diagnostic(at: charIndex, in: ns) {
                var actual = NSRange()
                let rect = tv.firstRect(forCharacterRange: NSRange(location: charIndex, length: 1), actualRange: &actual)
                hoverController.show(text: diag.message, near: rect)
                return
            }

            let (line, col) = position(in: tv.string, at: charIndex)
            guard let text = await parent.onRequestHover(line, col), !text.isEmpty else { return }

            var actual = NSRange()
            let rect = tv.firstRect(forCharacterRange: NSRange(location: charIndex, length: 1), actualRange: &actual)
            hoverController.show(text: text, near: rect)
        }

        private func handle(_ command: EditorCommand) {
            guard let tv = textView else { return }
            switch command {
            // Find/Replace can be summoned even when focus is elsewhere in the
            // window (e.g. the search field of an already-open bar, or the
            // terminal) — matching VS Code, where ⌘F/⌥⌘F always reach the
            // active editor. Every other editor command still requires the
            // text view itself to be focused, matching VS Code semantics.
            case .find:           findReplaceController?.present(withReplace: false)
            case .findAndReplace: findReplaceController?.present(withReplace: true)
            case .goToLine, .toggleComment, .indent, .outdent, .selectNextOccurrence,
                 .findReferences, .renameSymbol:
                guard tv.window?.firstResponder === tv else { return }
                switch command {
                case .goToLine:      promptGoToLine(tv)
                case .toggleComment: toggleComment(tv)
                case .indent:        shiftIndent(tv, indent: true)
                case .outdent:       shiftIndent(tv, indent: false)
                case .selectNextOccurrence: selectNextOccurrence(tv)
                case .findReferences: requestFindReferences(tv)
                case .renameSymbol:   promptRenameSymbol(tv)
                case .find, .findAndReplace: break // handled above
                }
            }
        }

        private var indentUnit: String {
            currentInsertSpaces ? String(repeating: " ", count: max(1, currentTabSize)) : "\t"
        }

        private func promptGoToLine(_ tv: NSTextView) {
            let alert = NSAlert()
            alert.messageText = "Go to Line"
            alert.informativeText = "Enter a line number:"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Go")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn,
                  let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
                  line >= 1
            else { return }

            let ns = tv.string as NSString
            var idx = 0
            var current = 1
            while current < line && idx < ns.length {
                let r = ns.range(of: "\n", options: [],
                                 range: NSRange(location: idx, length: ns.length - idx))
                if r.location == NSNotFound { break }
                idx = r.location + 1
                current += 1
            }
            let range = NSRange(location: min(idx, ns.length), length: 0)
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
        }

        // MARK: - Find All References (⌥⇧F12)

        /// Looks up `textDocument/references` at the caret and hands the
        /// result off to `AppState` (via `onFindReferences`) to populate the
        /// References panel. Unlike Cmd+Click "Go to Definition", this
        /// doesn't scroll this text view itself — the panel drives
        /// navigation for whichever result the user picks.
        private func requestFindReferences(_ tv: NSTextView) {
            let (line, col) = position(in: tv.string, at: tv.selectedRange().location)
            Task { [weak self] in
                await self?.parent.onFindReferences(line, col)
            }
        }

        // MARK: - Rename Symbol (F2)

        /// Prompts for a new name — mirroring `promptGoToLine`'s
        /// NSAlert-with-accessory-`NSTextField` modal exactly — pre-filled
        /// with the identifier touching the caret (found via the shared
        /// top-level `identifierWordRange`, also used by ⌘D's "select next
        /// occurrence" below, since it correctly grows in both directions
        /// from the caret rather than only backward like the
        /// completion-prefix helpers). Confirming invokes
        /// `onRenameSymbol` with the *start* of that identifier, the
        /// position convention LSP servers expect a rename request to point at.
        private func promptRenameSymbol(_ tv: NSTextView) {
            let ns = tv.string as NSString
            guard let word = identifierWordRange(in: ns, around: tv.selectedRange().location) else { return }
            let currentName = ns.substring(with: word)

            let alert = NSAlert()
            alert.messageText = "Rename Symbol"
            alert.informativeText = "Enter the new name for \"\(currentName)\":"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = currentName
            alert.accessoryView = field
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != currentName else { return }

            let (line, col) = position(in: tv.string, at: word.location)
            Task { [weak self] in
                await self?.parent.onRenameSymbol(line, col, newName)
            }
        }

        /// Comment token for the current language, or "" if line comments
        /// aren't well-defined for it.
        private var lineCommentToken: String {
            switch currentLanguage {
            case .python:                         return "#"
            case .swift, .typescript, .javascript,
                 .rust, .go, .css, .ds:            return "//"
            case .json, .html, .isml, .markdown, .plaintext: return ""
            }
        }

        private func toggleComment(_ tv: NSTextView) {
            let token = lineCommentToken
            guard !token.isEmpty else { return }

            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: tv.selectedRange())
            let block = ns.substring(with: lineRange)
            let hadTrailingNewline = block.hasSuffix("\n")
            var lines = block.components(separatedBy: "\n")
            if hadTrailingNewline { lines.removeLast() }

            let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allCommented = !nonBlank.isEmpty && nonBlank.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(token)
            }

            let newLines = lines.map { line -> String in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                if allCommented {
                    return Self.uncomment(line, token: token)
                } else {
                    let indent = line.prefix { $0 == " " || $0 == "\t" }
                    let rest   = line[indent.endIndex...]
                    return "\(indent)\(token) \(rest)"
                }
            }

            var newBlock = newLines.joined(separator: "\n")
            if hadTrailingNewline { newBlock += "\n" }
            replace(lineRange, with: newBlock, in: tv)
        }

        private static func uncomment(_ line: String, token: String) -> String {
            guard let r = line.range(of: token) else { return line }
            let before = line[..<r.lowerBound]
            var after  = line[r.upperBound...]
            // Drop a single space that followed the token, if any.
            if after.first == " " { after = after.dropFirst() }
            return String(before) + String(after)
        }

        private func shiftIndent(_ tv: NSTextView, indent: Bool) {
            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: tv.selectedRange())
            let block = ns.substring(with: lineRange)
            let hadTrailingNewline = block.hasSuffix("\n")
            var lines = block.components(separatedBy: "\n")
            if hadTrailingNewline { lines.removeLast() }

            let unit = indentUnit
            let newLines = lines.map { line -> String in
                if indent {
                    return line.isEmpty ? line : unit + line
                }
                // Outdent: remove one leading tab, or up to `tabSize` spaces.
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                var removed = 0
                var s = Substring(line)
                while removed < max(1, currentTabSize), s.first == " " {
                    s = s.dropFirst()
                    removed += 1
                }
                return String(s)
            }

            var newBlock = newLines.joined(separator: "\n")
            if hadTrailingNewline { newBlock += "\n" }
            replace(lineRange, with: newBlock, in: tv, selectWhole: true)
        }

        // MARK: - Option+Click add cursor

        /// Adds an empty range (a bare caret, no selection) at `charIndex` to
        /// the existing `selectedRanges` — wired from `AthenaTextView.onOptionClick`.
        /// A no-op if a caret already sits there. Typing afterward replaces
        /// at every caret at once via the same native AppKit multi-range
        /// editing that powers ⌘D (see `selectNextOccurrence` above).
        func addCursor(at charIndex: Int, in tv: NSTextView) {
            let maxLocation = (tv.string as NSString).length
            guard charIndex >= 0, charIndex <= maxLocation else { return }

            var ranges = tv.selectedRanges.map(\.rangeValue)
            let newRange = NSRange(location: charIndex, length: 0)
            guard !ranges.contains(where: { NSEqualRanges($0, newRange) }) else { return }

            ranges.append(newRange)
            ranges.sort { $0.location < $1.location }
            tv.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        }

        // MARK: - Select Next Occurrence (⌘D)

        /// `KeyAction.selectNextOccurrence` (⌘D). With a single empty caret,
        /// selects the word touching it. With any active selection(s) —
        /// typically already grown by a previous ⌘D — finds the next
        /// occurrence (case-sensitive, wrapping around the document) of the
        /// last range's exact text and adds it as another discontiguous
        /// range in `selectedRanges`. AppKit's native multi-range editing
        /// then replaces every selected range at once on the next keystroke;
        /// no hand-rolled multi-caret typing is needed (see `applyHighlighting`
        /// and `handleInsertText` for the places that had to be made
        /// multi-range-safe so they don't clobber this). No-op when there's
        /// no word under the caret, or no further occurrence exists.
        private func selectNextOccurrence(_ tv: NSTextView) {
            let ns = tv.string as NSString
            guard ns.length > 0 else { return }

            let ranges = tv.selectedRanges.map(\.rangeValue).sorted { $0.location < $1.location }
            guard !ranges.isEmpty else { return }

            // No selection yet: select the word under/touching the caret.
            if ranges.count == 1, ranges[0].length == 0 {
                guard let word = identifierWordRange(in: ns, around: ranges[0].location) else { return }
                tv.setSelectedRange(word)
                tv.scrollRangeToVisible(word)
                return
            }

            // Grow the chain: search for the next occurrence of the
            // last (highest-location) range's text, forward from its end,
            // wrapping around but stopping before the first occurrence in
            // the chain so a full circle with nothing new reports `nil`.
            guard let anchor = ranges.last, anchor.length > 0 else { return }
            let target = ns.substring(with: anchor)
            guard !target.isEmpty else { return }

            guard let found = nextOccurrence(
                of: target, in: ns,
                searchFrom: NSMaxRange(anchor),
                wrapLimit: ranges.first!.location
            ) else { return }

            var newRanges = ranges
            newRanges.append(found)
            newRanges.sort { $0.location < $1.location }
            tv.setSelectedRanges(newRanges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
            tv.scrollRangeToVisible(found)
        }


        /// Case-sensitive, literal search for `target` starting at `location`
        /// and running to the document end, then wrapping around to the
        /// document start — but only up to (excluding) `wrapLimit`, the
        /// chain's first occurrence, so wrapping all the way around without a
        /// *new* match correctly reports `nil` instead of re-finding a range
        /// that's already selected.
        private func nextOccurrence(of target: String, in ns: NSString, searchFrom location: Int, wrapLimit: Int) -> NSRange? {
            if location < ns.length {
                let tail = NSRange(location: location, length: ns.length - location)
                let r = ns.range(of: target, options: [.literal], range: tail)
                if r.location != NSNotFound { return r }
            }
            guard wrapLimit > 0 else { return nil }
            let head = NSRange(location: 0, length: min(wrapLimit, ns.length))
            let r = ns.range(of: target, options: [.literal], range: head)
            return r.location == NSNotFound ? nil : r
        }

        /// Inserts a newline followed by the same leading indentation as the
        /// current line, bumped one level deeper when the character just
        /// before the cursor opens a block (`{`, `(`, `[`, `:`). Returns `true`
        /// having consumed the event, so callers should suppress the default
        /// NSTextView newline handling.
        private func handleAutoIndentReturn(in tv: NSTextView) -> Bool {
            let range = tv.selectedRange()
            let ns = tv.string as NSString
            let cursor = range.location

            // Walk back to the start of the current line.
            var lineStart = cursor
            while lineStart > 0, ns.character(at: lineStart - 1) != 0x0A /* \n */ {
                lineStart -= 1
            }

            // Leading whitespace of the current line, up to the cursor.
            var indentEnd = lineStart
            while indentEnd < cursor {
                let c = ns.character(at: indentEnd)
                guard c == 0x20 /* space */ || c == 0x09 /* tab */ else { break }
                indentEnd += 1
            }
            let currentIndent = ns.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))

            // One extra indent level after an opening bracket or a trailing colon.
            var newIndent = currentIndent
            if cursor > 0 {
                switch ns.character(at: cursor - 1) {
                case 0x7B, 0x28, 0x5B, 0x3A: // { ( [ :
                    newIndent += indentUnit
                default:
                    break
                }
            }

            replace(range, with: "\n" + newIndent, in: tv)
            return true
        }

        /// Replaces `range` with `text` through the undo-aware path and keeps
        /// highlighting and the bound content in sync.
        private func replace(_ range: NSRange, with text: String, in tv: NSTextView, selectWhole: Bool = false) {
            guard tv.shouldChangeText(in: range, replacementString: text) else { return }
            tv.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            if selectWhole {
                tv.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
            }
        }

        // MARK: Bracket/quote auto-close, type-through, wrap-selection

        /// Opening bracket → its closer. Shared with bracket-pair match
        /// highlighting and the Backspace pair-delete below.
        private static let bracketOpeners: [unichar: unichar] = [
            0x28: 0x29,  // ( -> )
            0x5B: 0x5D,  // [ -> ]
            0x7B: 0x7D,  // { -> }
        ]
        /// Closing bracket → its opener (inverse of `bracketOpeners`).
        private static let bracketClosers: [unichar: unichar] = [
            0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B,
        ]
        /// Quote characters, where the same glyph opens and closes a pair.
        private static let quoteChars: Set<unichar> = [0x22, 0x27, 0x60]  // " ' `

        /// Called by `AthenaTextView.insertText` before AppKit inserts typed
        /// text. VS Code-style pairing:
        /// - Typing an opener around a selection wraps the selection in the
        ///   pair, preserving it inside.
        /// - Typing an opener with no selection inserts the pair and leaves
        ///   the caret between the two characters.
        /// - Typing a closer (bracket or quote) "types through" when the very
        ///   next character is already that exact closer, instead of
        ///   inserting a duplicate.
        /// Returns `true` to consume the insertion; `false` lets AppKit's
        /// default `insertText` handle it (plain characters, multi-char
        /// paste/IME commits are never routed here — see `AthenaTextView`).
        func handleInsertText(_ string: String) -> Bool {
            guard let tv = textView, string.utf16.count == 1, let ch = string.utf16.first else { return false }

            // Multi-range selections (a ⌘D chain, or ⌥Click carets) must fall
            // through to AppKit's native multi-range `insertText` — every
            // check below only reasons about `tv.selectedRange()` (the
            // primary range), so handling it here would apply the pairing
            // logic to just one range and silently drop the others.
            guard tv.selectedRanges.count <= 1 else { return false }

            let selection = tv.selectedRange()

            // Wrap a non-empty selection in the pair rather than replacing it.
            if selection.length > 0 {
                if let closer = Self.bracketOpeners[ch] {
                    wrapSelection(selection, opener: ch, closer: closer, in: tv)
                    return true
                }
                if Self.quoteChars.contains(ch) {
                    wrapSelection(selection, opener: ch, closer: ch, in: tv)
                    return true
                }
                return false
            }

            let ns = tv.string as NSString
            let cursor = selection.location
            let nextChar: unichar? = cursor < ns.length ? ns.character(at: cursor) : nil

            if let closer = Self.bracketOpeners[ch] {
                insertPair(opener: ch, closer: closer, at: cursor, in: tv)
                return true
            }
            if Self.quoteChars.contains(ch) {
                if nextChar == ch {
                    tv.setSelectedRange(NSRange(location: cursor + 1, length: 0))
                    return true
                }
                insertPair(opener: ch, closer: ch, at: cursor, in: tv)
                return true
            }
            if Self.bracketClosers[ch] != nil, nextChar == ch {
                tv.setSelectedRange(NSRange(location: cursor + 1, length: 0))
                return true
            }
            return false
        }

        /// Inserts `opener`+`closer` at `cursor` and leaves the caret between them.
        private func insertPair(opener: unichar, closer: unichar, at cursor: Int, in tv: NSTextView) {
            let text  = String(utf16CodeUnits: [opener, closer], count: 2)
            let range = NSRange(location: cursor, length: 0)
            guard tv.shouldChangeText(in: range, replacementString: text) else { return }
            tv.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: cursor + 1, length: 0))
        }

        /// Wraps `range` in `opener`/`closer`, keeping the original selection
        /// preserved (now shifted one character in) inside the new pair.
        private func wrapSelection(_ range: NSRange, opener: unichar, closer: unichar, in tv: NSTextView) {
            let ns    = tv.string as NSString
            let inner = ns.substring(with: range)
            let text  = String(utf16CodeUnits: [opener], count: 1) + inner + String(utf16CodeUnits: [closer], count: 1)
            guard tv.shouldChangeText(in: range, replacementString: text) else { return }
            tv.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + 1, length: range.length))
        }

        /// Deletes both characters of an auto-inserted empty pair (`()`,
        /// `""`, …) in one step when the caret sits directly between them, so
        /// Backspace doesn't leave a dangling closer behind. Called from
        /// `handleKeyDown` on the Backspace key. Returns `true` if handled.
        private func deleteEmptyPairIfPresent(in tv: NSTextView) -> Bool {
            // As in `handleInsertText`: bail out to native multi-range
            // Backspace when more than one range/caret is selected, rather
            // than acting only on the primary one and swallowing the event.
            guard tv.selectedRanges.count <= 1 else { return false }
            let selection = tv.selectedRange()
            guard selection.length == 0, selection.location > 0 else { return false }
            let ns = tv.string as NSString
            let cursor = selection.location
            guard cursor < ns.length else { return false }
            let before = ns.character(at: cursor - 1)
            let after  = ns.character(at: cursor)
            let isEmptyPair = Self.bracketOpeners[before] == after
                || (Self.quoteChars.contains(before) && before == after)
            guard isEmptyPair else { return false }

            let range = NSRange(location: cursor - 1, length: 2)
            guard tv.shouldChangeText(in: range, replacementString: "") else { return false }
            tv.replaceCharacters(in: range, with: "")
            tv.didChangeText()
            return true
        }

        // MARK: Highlighting

        func applyHighlighting(to textView: NSTextView) {
            let attributed = highlighter.highlight(textView.string)

            // Preserve every selected range — not just the primary one — so a
            // multi-range selection (a ⌘D chain, or ⌥Click carets) survives
            // this re-highlight, which runs after *every* keystroke via
            // `textDidChange`. Using the singular `selectedRange`/`setSelectedRange`
            // here would silently collapse a multi-range selection back down
            // to one range right after the first character typed into it.
            let selectedRanges = textView.selectedRanges
            textView.textStorage?.setAttributedString(attributed)
            let maxLocation = (textView.string as NSString).length
            let validRanges = selectedRanges.filter { NSMaxRange($0.rangeValue) <= maxLocation }
            if !validRanges.isEmpty {
                textView.setSelectedRanges(validRanges, affinity: .downstream, stillSelecting: false)
            }

            // After overwriting all attributes, re-stamp import paths with
            // NSLinkAttributeName so Cmd+Click fires textView(_:clickedOnLink:at:).
            addImportLinkAttributes(to: textView)
        }

        private func addImportLinkAttributes(to textView: NSTextView) {
            guard let ts = textView.textStorage else { return }
            let text     = ts.string as NSString
            let keywords = ["import ", "require(", " from ", "@import", "#include", "export "]
            var pos      = 0
            ts.beginEditing()
            while pos < text.length {
                let lineRange = text.lineRange(for: NSRange(location: pos, length: 0))
                let line      = text.substring(with: lineRange)
                if keywords.contains(where: { line.contains($0) }) {
                    var i       = lineRange.location
                    let lineEnd = NSMaxRange(lineRange)
                    while i < lineEnd {
                        let c = text.character(at: i)
                        if c == 34 || c == 39 || c == 96 {   // " ' `
                            let openQ    = c
                            let pathStart = i + 1
                            i += 1
                            while i < lineEnd {
                                if text.character(at: i) == openQ {
                                    let r    = NSRange(location: pathStart, length: i - pathStart)
                                    let path = text.substring(with: r)
                                    if !path.isEmpty {
                                        ts.addAttribute(.link, value: path, range: r)
                                    }
                                    i += 1
                                    break
                                }
                                i += 1
                            }
                        } else { i += 1 }
                    }
                }
                let next = NSMaxRange(lineRange)
                guard next > pos else { break }
                pos = next
            }
            ts.endEditing()
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onContentChange(textView.string)
            applyHighlighting(to: textView)

            // Dismiss ghost text and hover tooltip on every keystroke; reschedule both triggers.
            completionDebounce?.cancel()
            ghostDebounce?.cancel()
            ghostController.dismiss()
            cancelHover()

            completionDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms
                guard !Task.isCancelled, let self else { return }
                await self.triggerCompletion()
            }
            ghostDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)  // 700 ms
                guard !Task.isCancelled, let self else { return }
                await self.triggerGhostText()
            }
        }

        // Called by NSTextView when Cmd+Click lands on a .link attribute (editable TV).
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let path = link as? String else { return false }
            parent.onImportClick(path, parent.fileURL)
            return true   // handled — don't let NSTextView try to open it as a URL
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let (line, col) = cursorPosition(in: textView)
            parent.onCursorMove(line, col)
            updateBlameLabel(
                in: textView,
                fontSize: parent.fontSize,
                fontFamily: parent.fontFamily,
                theme: parent.theme
            )
            updateBracketMatchHighlight(in: textView)
            updateDiagnosticHighlights(in: textView)
            updateActiveSnippetTracking(for: textView)
        }

        /// Keeps the active snippet's tab-stop ranges correct as edits land
        /// in the buffer: shrinks/grows the current stop in place when the
        /// edit falls inside it, and shifts every later stop by the same
        /// length delta — the same offset bookkeeping `applyLSPTextEdits`
        /// does for a batch of edits, applied here to one live edit at a
        /// time. Always returns `true`; this hook only tracks state; it
        /// never blocks an edit. Runs for every text change (typed, pasted,
        /// or programmatic via `shouldChangeText(in:replacementString:)` —
        /// e.g. bracket auto-close), which is harmless since it's a no-op
        /// whenever no snippet is active.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard var snippet = activeSnippet else { return true }
            let delta = (replacementString?.utf16.count ?? 0) - affectedCharRange.length
            guard delta != 0 else { return true }

            for i in snippet.stops.indices {
                var range = snippet.stops[i].range
                if i == snippet.currentIndex,
                   affectedCharRange.location >= range.location,
                   NSMaxRange(affectedCharRange) <= NSMaxRange(range) {
                    range.length += delta
                } else if range.location >= NSMaxRange(affectedCharRange) {
                    range.location += delta
                }
                snippet.stops[i].range = range
            }
            activeSnippet = snippet
            return true
        }

        // MARK: Blame annotation

        func updateBlameLabel(in textView: NSTextView, fontSize: CGFloat, fontFamily: String, theme: EditorTheme) {
            guard let label = blameAnnotationLabel else { return }

            let cursorIdx = textView.selectedRange().location
            guard let layoutManager = textView.layoutManager,
                  textView.textContainer != nil
            else { label.alphaValue = 0; return }

            // Compute current 1-based line number
            let nsString = textView.string as NSString
            let safeIdx  = min(cursorIdx, nsString.length)
            var line = 1
            for i in 0..<safeIdx {
                if nsString.character(at: i) == 0x0A { line += 1 }
            }

            guard let blameLine = currentBlameInfo[line] else {
                label.alphaValue = 0
                return
            }

            // Position: find the last glyph on this line's fragment, then place label after it.
            let lineCharRange = nsString.lineRange(for: NSRange(location: safeIdx, length: 0))
            let glyphRange    = layoutManager.glyphRange(forCharacterRange: lineCharRange,
                                                         actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
                label.alphaValue = 0
                return
            }

            let usedRect  = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location,
                                                               effectiveRange: nil)
            let inset     = textView.textContainerInset
            let labelX    = usedRect.maxX + inset.width + 20
            let labelY    = usedRect.minY + inset.height

            label.attributedStringValue = blameAttributedString(
                blameLine, fontSize: fontSize - 1, theme: theme
            )
            label.sizeToFit()
            label.frame.origin = CGPoint(x: labelX, y: labelY)
            label.alphaValue   = 1
        }

        private func blameAttributedString(_ b: BlameLine, fontSize: CGFloat, theme: EditorTheme) -> NSAttributedString {
            let font  = NSFont.monospacedSystemFont(ofSize: max(fontSize, 10), weight: .regular)
            let color = NSColor(white: 0.55, alpha: 0.75)
            let attrs: [NSAttributedString.Key: Any] = [
                .font:           font,
                .foregroundColor: color,
            ]
            let summary = b.summary.count > 60 ? String(b.summary.prefix(57)) + "…" : b.summary
            let text    = "\(b.author)  ·  \(relativeDate(b.date))  ·  \(summary)"
            return NSAttributedString(string: text, attributes: attrs)
        }

        private func relativeDate(_ date: Date) -> String {
            let seconds = Int(-date.timeIntervalSinceNow)
            switch seconds {
            case ..<60:          return "just now"
            case 60..<3600:      return "\(seconds / 60)m ago"
            case 3600..<86400:   return "\(seconds / 3600)h ago"
            case 86400..<604800: return "\(seconds / 86400)d ago"
            case 604800..<2592000: return "\(seconds / 604800)w ago"
            case 2592000..<31536000: return "\(seconds / 2592000)mo ago"
            default:             return "\(seconds / 31536000)y ago"
            }
        }

        // MARK: - Bracket-pair match highlighting

        /// Finds the bracket touching the caret — checking just after it,
        /// then just before — and its matching partner via a simple
        /// depth-counting scan (not a full parser: differently-typed nested
        /// brackets aren't tracked), then paints a subtle background on both
        /// via temporary layout-manager attributes. Mirrors
        /// `FindReplaceController`'s match highlighting so it can't be
        /// clobbered by, or clobber, syntax highlighting or the undo stack.
        /// Called on every selection change; only the two previously-painted
        /// ranges are cleared, so unrelated highlights (e.g. find matches)
        /// are left alone.
        private func updateBracketMatchHighlight(in textView: NSTextView) {
            guard let lm = textView.layoutManager else { return }
            let textLength = (textView.string as NSString).length
            for r in highlightedBracketRanges where NSMaxRange(r) <= textLength {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
            }
            highlightedBracketRanges = []

            let selection = textView.selectedRange()
            guard selection.length == 0 else { return }

            let ns = textView.string as NSString
            guard let (openIdx, closeIdx) = matchingBracketPair(in: ns, atCursor: selection.location) else { return }

            let color  = currentTheme.selection.withAlphaComponent(0.55)
            let ranges = [NSRange(location: openIdx, length: 1), NSRange(location: closeIdx, length: 1)]
            for r in ranges { lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: r) }
            highlightedBracketRanges = ranges
        }

        /// Looks at the characters immediately after, then before, the caret;
        /// if either is a bracket, scans for its matching partner and returns
        /// both indices (opener first, closer second).
        private func matchingBracketPair(in ns: NSString, atCursor cursor: Int) -> (Int, Int)? {
            for idx in [cursor, cursor - 1] where idx >= 0 && idx < ns.length {
                let c = ns.character(at: idx)
                if let closer = Self.bracketOpeners[c],
                   let match = scanForBracketMatch(in: ns, from: idx + 1, same: c, other: closer, step: 1) {
                    return (idx, match)
                }
                if let opener = Self.bracketClosers[c],
                   let match = scanForBracketMatch(in: ns, from: idx - 1, same: c, other: opener, step: -1) {
                    return (match, idx)
                }
            }
            return nil
        }

        /// Depth-counting scan in `step` direction (±1) from `start`: `same`
        /// (the bracket kind scanned from) increments depth, `other` (its
        /// partner) decrements it, and the index where depth returns to zero
        /// is the match.
        private func scanForBracketMatch(in ns: NSString, from start: Int, same: unichar, other: unichar, step: Int) -> Int? {
            var depth = 1
            var i = start
            while i >= 0, i < ns.length {
                let c = ns.character(at: i)
                if c == same {
                    depth += 1
                } else if c == other {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i += step
            }
            return nil
        }

        // MARK: - Diagnostic squiggle underlines

        /// Reapplies squiggle-underline temporary attributes for every entry
        /// in `currentDiagnostics` — see the property's doc comment for why
        /// this must be re-run after every keystroke (hooked into
        /// `textViewDidChangeSelection` above) as well as whenever a fresh
        /// diagnostics batch arrives from `AppState` (`EditorView.updateNSView`).
        /// Mirrors `updateBracketMatchHighlight`'s clear-then-repaint shape.
        /// Severity → style: `.error`/`.warning` get a themed dotted
        /// underline; `.information` gets a thin, low-alpha one; `.hint` gets
        /// none at all (plan.md item 15: "no underline, or a very subtle one,
        /// for .information/.hint").
        func updateDiagnosticHighlights(in textView: NSTextView) {
            guard let lm = textView.layoutManager else { return }
            let textLength = (textView.string as NSString).length
            for r in highlightedDiagnosticRanges where NSMaxRange(r) <= textLength {
                lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: r)
                lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: r)
            }
            highlightedDiagnosticRanges = []
            guard !currentDiagnostics.isEmpty else { return }

            let ns = textView.string as NSString
            var newRanges: [NSRange] = []
            for diagnostic in currentDiagnostics {
                guard diagnostic.severity != .hint,
                      let range = diagnosticRange(for: diagnostic, in: ns),
                      NSMaxRange(range) <= textLength
                else { continue }

                let color: NSColor
                let style: Int
                switch diagnostic.severity {
                case .error:
                    color = currentTheme.diagnosticError
                    style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                case .warning:
                    color = currentTheme.diagnosticWarning
                    style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                case .information:
                    color = currentTheme.diagnosticInfo.withAlphaComponent(0.5)
                    style = NSUnderlineStyle.single.rawValue
                case .hint:
                    continue  // excluded above; unreachable
                }
                lm.addTemporaryAttribute(.underlineStyle, value: style, forCharacterRange: range)
                lm.addTemporaryAttribute(.underlineColor, value: color, forCharacterRange: range)
                newRanges.append(range)
            }
            highlightedDiagnosticRanges = newRanges
        }

        /// Converts a diagnostic's 1-based line/column point into the
        /// `NSRange` to underline. `Diagnostic` (see `SharedTypes.swift`)
        /// carries only a point from the LSP, not an explicit end — so this
        /// underlines the identifier/word touching that point
        /// (`identifierWordRange`, shared with Cmd+Click/rename/⌘D) when
        /// there is one, falling back to the whole line (minus its line
        /// terminator) when the point doesn't land on an identifier.
        private func diagnosticRange(for diagnostic: Diagnostic, in ns: NSString) -> NSRange? {
            guard ns.length > 0 else { return nil }
            let charIndex = characterIndex(forLine: diagnostic.line, column: diagnostic.column, in: ns)
            guard charIndex >= 0, charIndex < ns.length else { return nil }

            if let wordRange = identifierWordRange(in: ns, around: charIndex) {
                return wordRange
            }

            let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
            var length = lineRange.length
            if length > 0, ns.character(at: lineRange.location + length - 1) == 0x0A {
                length -= 1
                if length > 0, ns.character(at: lineRange.location + length - 1) == 0x0D { length -= 1 }
            }
            guard length > 0 else { return nil }
            return NSRange(location: lineRange.location, length: length)
        }

        /// 1-based line/column → character offset. Same line-walking
        /// convention as `EditorScrollProxy.jumpTo`/`promptGoToLine` (the
        /// reverse of `position(in:at:)` below), duplicated here rather than
        /// shared since none of those call sites have a common seam today.
        private func characterIndex(forLine line: Int, column: Int, in ns: NSString) -> Int {
            var idx = 0
            var current = 1
            while current < line && idx < ns.length {
                let r = ns.range(of: "\n", options: [], range: NSRange(location: idx, length: ns.length - idx))
                if r.location == NSNotFound { break }
                idx = r.location + 1
                current += 1
            }
            let lineRange = ns.lineRange(for: NSRange(location: min(idx, ns.length), length: 0))
            return min(idx + max(1, column) - 1, NSMaxRange(lineRange))
        }

        /// The diagnostic (if any) whose squiggle range contains `charIndex` —
        /// computed from the same `diagnosticRange` used to paint the
        /// underlines, so "hovering the squiggle" can't disagree with where
        /// it's actually drawn. Excludes `.hint` (never underlined, so never
        /// hover-prioritized either). Checked first, and prioritized over an
        /// LSP hover round-trip, from `triggerHover` below — it's just a
        /// local array scan, no I/O.
        private func diagnostic(at charIndex: Int, in ns: NSString) -> Diagnostic? {
            for diagnostic in currentDiagnostics where diagnostic.severity != .hint {
                if let range = diagnosticRange(for: diagnostic, in: ns), NSLocationInRange(charIndex, range) {
                    return diagnostic
                }
            }
            return nil
        }

        /// Escape with multiple ranges/carets selected: drop back to a single
        /// cursor at the last (highest-location) range, mirroring VS Code's
        /// "remove secondary cursors" behavior.
        private func collapseToSingleCursor(_ tv: NSTextView) {
            guard let last = tv.selectedRanges.map(\.rangeValue).max(by: { $0.location < $1.location }) else { return }
            tv.setSelectedRange(last)
        }

        // MARK: - Key interception (completion popup + ghost text)

        /// Called by `AthenaTextView.keyDown` before AppKit processes the event.
        /// Returns `true` to consume the event.
        func handleKeyDown(_ event: NSEvent) -> Bool {
            // Any keystroke dismisses a pending/visible hover tooltip —
            // including Escape (case 53 below also dismisses the popup,
            // ghost text, and find bar).
            cancelHover()

            switch event.keyCode {
            case 36:  // Return — accept completion, or auto-indent the new line
                if completionController.isVisible {
                    return completionController.confirmSelection()
                }
                // Multi-range selections fall through to native multi-range
                // Return handling (a plain "\n" at every range) rather than
                // this single-range indent computation.
                if currentAutoIndent, let tv = textView, tv.selectedRanges.count <= 1 {
                    return handleAutoIndentReturn(in: tv)
                }
                return false
            case 48:  // Tab — accept completion, accept ghost text, or advance snippet tab stop
                if completionController.isVisible {
                    return completionController.confirmSelection()
                }
                if ghostController.hasSuggestion, let tv = textView {
                    let accepted = ghostController.accept(in: tv)
                    if accepted {
                        parent.onContentChange(tv.string)
                        applyHighlighting(to: tv)
                    }
                    return accepted
                }
                if let tv = textView, advanceSnippet(in: tv) {
                    return true
                }
                return false
            case 51:  // Backspace — delete an auto-inserted empty pair as a unit
                if let tv = textView, deleteEmptyPairIfPresent(in: tv) { return true }
                return false
            case 53:  // Escape — dismiss popup, ghost text, the find/replace bar, multi-cursor, or a snippet
                if completionController.isVisible  { completionController.dismiss(); return true }
                if ghostController.hasSuggestion    { ghostController.dismiss();      return true }
                if findReplaceController?.isVisible == true { findReplaceController?.dismiss(); return true }
                if let tv = textView, tv.selectedRanges.count > 1 {
                    collapseToSingleCursor(tv)
                    return true
                }
                if activeSnippet != nil {
                    activeSnippet = nil
                    return true
                }
                return false
            case 125: // Down arrow — navigate popup
                if completionController.isVisible  { completionController.moveDown(); return true }
                return false
            case 126: // Up arrow — navigate popup
                if completionController.isVisible  { completionController.moveUp();   return true }
                return false
            default:
                return false
            }
        }

        // MARK: - Completion trigger

        private func triggerCompletion() async {
            guard let tv = textView else { return }
            let (line, col) = cursorPosition(in: tv)
            let word = currentWord(in: tv)

            // Trigger only when the cursor is in a word or immediately after "."
            let nsStr = tv.string as NSString
            let idx   = tv.selectedRange().location
            let prev  = idx > 0 ? nsStr.character(at: idx - 1) : 0
            guard !word.isEmpty || prev == 46 /* "." */ else {
                completionController.dismiss()
                return
            }

            let items = await parent.onRequestCompletion(line, col)
            guard !items.isEmpty else { completionController.dismiss(); return }

            let lower    = word.lowercased()
            let filtered = word.isEmpty
                ? Array(items.prefix(20))
                : items.filter { $0.label.lowercased().hasPrefix(lower) }.prefix(20).map { $0 }

            guard !filtered.isEmpty else { completionController.dismiss(); return }

            let wRange  = currentWordRange(in: tv)
            var actual  = NSRange()
            let screenRect = tv.firstRect(
                forCharacterRange: NSRange(location: wRange.location, length: 0),
                actualRange: &actual
            )

            completionController.show(items: filtered, wordRange: wRange, screenRect: screenRect)
            completionController.onAccept = { [weak self, weak tv] item, range in
                guard let self, let textView = tv else { return }
                self.insertCompletion(item, wordRange: range, in: textView)
            }
        }

        // MARK: - Ghost text trigger

        private func triggerGhostText() async {
            guard let tv = textView else { return }
            let cursorIdx = tv.selectedRange().location
            let text      = tv.string
            guard cursorIdx > 0 else { return }

            let prefix = String(text.prefix(cursorIdx))
            let suffix = String(text.suffix(text.count - min(cursorIdx, text.count)))

            // Need at least some code before the cursor to complete from; fill-in-middle
            // still works right after whitespace (e.g. after `return ` or a fresh indent).
            guard prefix.contains(where: { !$0.isWhitespace }) else { return }

            guard let suggestion = await parent.onRequestGhostText(prefix, suffix) else { return }
            guard !suggestion.isEmpty else { return }

            let font = tv.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            ghostController.show(text: suggestion, after: cursorIdx, font: font, in: tv)
        }

        // MARK: - Completion helpers

        private func currentWord(in textView: NSTextView) -> String {
            let idx  = textView.selectedRange().location
            let text = textView.string as NSString
            var start = idx
            while start > 0 {
                let c = text.character(at: start - 1)
                if c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) {
                    start -= 1
                } else { break }
            }
            return text.substring(with: NSRange(location: start, length: idx - start))
        }

        private func currentWordRange(in textView: NSTextView) -> NSRange {
            let idx  = textView.selectedRange().location
            let text = textView.string as NSString
            var start = idx
            while start > 0 {
                let c = text.character(at: start - 1)
                if c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) {
                    start -= 1
                } else { break }
            }
            return NSRange(location: start, length: idx - start)
        }

        /// Inserts the completion's text, expanding it as a snippet
        /// (`$1`/`${1:placeholder}`/`$0`) via `SnippetEngine` when it's
        /// shaped like one. A snippet with two or more tab stops becomes
        /// "active" — its first stop's range is selected (placeholder text
        /// selected so typing overwrites it, mirroring `wrapSelection`'s
        /// post-insertion selection above) and Tab (see `handleKeyDown`)
        /// cycles through the rest. Plain text (no `$`-markers, the common
        /// case) or a snippet with only an implicit/explicit `$0` behaves
        /// exactly as before: caret placed at the single relevant point, no
        /// tracking set up.
        private func insertCompletion(_ item: CompletionItem, wordRange: NSRange, in textView: NSTextView) {
            guard let ts = textView.textStorage else { return }
            let raw      = item.insertText.isEmpty ? item.label : item.insertText
            let expanded = SnippetEngine.expand(raw)
            ts.beginEditing()
            ts.replaceCharacters(in: wordRange, with: expanded.text)
            ts.endEditing()

            switch expanded.tabStops.count {
            case 0:
                textView.setSelectedRange(NSRange(location: wordRange.location + (expanded.text as NSString).length, length: 0))
                activeSnippet = nil
            case 1:
                // Only the (implicit or explicit) final stop — nothing to
                // Tab-cycle; just land the caret there.
                let stop = expanded.tabStops[0]
                textView.setSelectedRange(NSRange(location: stop.range.location + wordRange.location, length: stop.range.length))
                activeSnippet = nil
            default:
                let stops = expanded.tabStops.map {
                    SnippetTabStop(index: $0.index, range: NSRange(location: $0.range.location + wordRange.location, length: $0.range.length))
                }
                activeSnippet = ActiveSnippet(stops: stops, currentIndex: 0)
                textView.setSelectedRange(stops[0].range)
            }

            parent.onContentChange(textView.string)
            applyHighlighting(to: textView)
            completionController.dismiss()
        }

        /// Advances the active snippet to its next tab stop, selecting that
        /// stop's range. Returns `false` when no snippet is active (so the
        /// caller — Tab's priority chain in `handleKeyDown` — falls through
        /// to normal Tab handling); otherwise returns `true`, consuming the
        /// keystroke even when this was the final stop (landing on `$0`
        /// ends tracking, but the Tab that got you there is still handled,
        /// not passed through as a literal tab character).
        private func advanceSnippet(in tv: NSTextView) -> Bool {
            guard var snippet = activeSnippet else { return false }
            let nextIndex = snippet.currentIndex + 1
            guard nextIndex < snippet.stops.count else { return true }

            snippet.currentIndex = nextIndex
            activeSnippet = snippet
            tv.setSelectedRange(snippet.stops[nextIndex].range)
            if snippet.isOnFinalStop {
                activeSnippet = nil
            }
            return true
        }

        /// Cancels the active snippet's tracking when the selection moves
        /// outside the current stop's range — a mouse click elsewhere, or
        /// an arrow-key move out of the placeholder. Typing inside the
        /// current stop keeps it alive: `shouldChangeTextIn` below grows/
        /// shrinks that stop's tracked range in lockstep with the edit
        /// before this runs, so the resulting caret position still falls
        /// within it.
        private func updateActiveSnippetTracking(for textView: NSTextView) {
            guard let snippet = activeSnippet else { return }
            let current   = snippet.currentRange
            let selection = textView.selectedRange()
            let withinCurrentStop = selection.location >= current.location
                && NSMaxRange(selection) <= NSMaxRange(current)
            if !withinCurrentStop {
                activeSnippet = nil
            }
        }

        /// Cancels any active snippet's tab-stop tracking. Called by
        /// `EditorView.updateNSView` whenever the reused text view's content
        /// is swapped for a different tab/file (`textView.string != content`)
        /// — a snippet's ranges are only meaningful against the document
        /// they were created in, and that swap happens via a direct
        /// `textView.string =` assignment that (deliberately, like
        /// `textDidChange`) never reaches `shouldChangeTextIn`/
        /// `textViewDidChangeSelection`, so nothing else would clear it.
        func cancelActiveSnippet() {
            activeSnippet = nil
        }

        // MARK: Private

        /// Computes 1-based line and column numbers for the current cursor offset.
        private func cursorPosition(in textView: NSTextView) -> (line: Int, column: Int) {
            position(in: textView.string, at: textView.selectedRange().location)
        }

        /// Computes 1-based line/column for an arbitrary character offset —
        /// not necessarily the current selection. Shared by `cursorPosition`
        /// above and by Cmd+Click "Go to Definition" / hover-dwell lookups,
        /// which both need the position of the *clicked/hovered* index.
        private func position(in text: String, at charIndex: Int) -> (line: Int, column: Int) {
            let nsString = text as NSString
            let safeOffset = min(max(charIndex, 0), nsString.length)

            var line = 1
            var lineStartOffset = 0

            for i in 0..<safeOffset {
                if nsString.character(at: i) == 0x0A { // newline
                    line += 1
                    lineStartOffset = i + 1
                }
            }

            let column = safeOffset - lineStartOffset + 1
            return (line, column)
        }
    }
}
