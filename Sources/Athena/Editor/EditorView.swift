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
    /// The URL of the file being edited — used for import path resolution.
    var fileURL: URL? = nil
    var onCursorMove: (Int, Int) -> Void = { _, _ in }
    var onContentChange: (String) -> Void = { _ in }
    /// Called whenever the scroll position changes. (fraction 0‥1, visible ratio 0‥1)
    var onScrollChange: (Double, Double) -> Void = { _, _ in }
    /// Called when the user clicks on a quoted import path string.
    /// First argument is the raw path (e.g. `"./configs"`), second is the current file URL.
    var onImportClick: (String, URL?) -> Void = { _, _ in }
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

        // Wire Cmd+Click: the subclass calls back with the char index.
        let coord = context.coordinator
        textView.onCmdClick = { [weak coord, weak textView] (charIdx: Int) in
            guard let coord, let tv = textView else { return }
            guard let path = coord.importPath(from: tv.string, at: charIdx) else { return }
            coord.parent.onImportClick(path, coord.parent.fileURL)
        }

        // Switch to the pointing-hand cursor while Cmd-hovering a clickable target.
        textView.isClickableTarget = { [weak coord, weak textView] (charIdx: Int) in
            guard let coord, let tv = textView else { return false }
            return coord.isCmdClickable(in: tv.string, at: charIdx)
        }

        // Wire key interception for completion popup and ghost text accept.
        textView.onKeyDown = { [weak coord] event in
            coord?.handleKeyDown(event) ?? false
        }

        // Dismiss popup and ghost text on any click so they don't block Cmd+Click.
        textView.onMouseDown = { [weak coord] in
            coord?.completionController.dismiss()
            coord?.ghostController.dismiss()
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
        } else if themeChanged || fontChanged {
            coord.applyHighlighting(to: textView)
        }

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

        // Completion popup and ghost text
        let completionController = CompletionWindowController()
        let ghostController      = GhostTextController()
        @ObservationIgnored private var completionDebounce: Task<Void, Never>?
        @ObservationIgnored private var ghostDebounce:      Task<Void, Never>?

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
            return Self.isIdentifierChar(ns.character(at: charIndex))
        }

        /// ASCII identifier characters: `A–Z`, `a–z`, `0–9`, `_`, `$`.
        private static func isIdentifierChar(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90)  ||   // A–Z
            (c >= 97 && c <= 122) ||   // a–z
            (c >= 48 && c <= 57)  ||   // 0–9
            c == 95 || c == 36         // _ $
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
            case .goToLine, .toggleComment, .indent, .outdent:
                guard tv.window?.firstResponder === tv else { return }
                switch command {
                case .goToLine:      promptGoToLine(tv)
                case .toggleComment: toggleComment(tv)
                case .indent:        shiftIndent(tv, indent: true)
                case .outdent:       shiftIndent(tv, indent: false)
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

        // MARK: Highlighting

        func applyHighlighting(to textView: NSTextView) {
            let attributed = highlighter.highlight(textView.string)

            // Preserve the current selection so the cursor doesn't jump.
            let selectedRange = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributed)
            let maxLocation = (textView.string as NSString).length
            if selectedRange.location <= maxLocation {
                textView.setSelectedRange(selectedRange)
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

            // Dismiss ghost text on every keystroke; reschedule both triggers.
            completionDebounce?.cancel()
            ghostDebounce?.cancel()
            ghostController.dismiss()

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

        // MARK: - Key interception (completion popup + ghost text)

        /// Called by `AthenaTextView.keyDown` before AppKit processes the event.
        /// Returns `true` to consume the event.
        func handleKeyDown(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 36:  // Return — accept completion, or auto-indent the new line
                if completionController.isVisible {
                    return completionController.confirmSelection()
                }
                if currentAutoIndent, let tv = textView {
                    return handleAutoIndentReturn(in: tv)
                }
                return false
            case 48:  // Tab — accept completion or ghost text
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
                return false
            case 53:  // Escape — dismiss popup, ghost text, or the find/replace bar
                if completionController.isVisible  { completionController.dismiss(); return true }
                if ghostController.hasSuggestion    { ghostController.dismiss();      return true }
                if findReplaceController?.isVisible == true { findReplaceController?.dismiss(); return true }
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

        private func insertCompletion(_ item: CompletionItem, wordRange: NSRange, in textView: NSTextView) {
            guard let ts = textView.textStorage else { return }
            let text = item.insertText.isEmpty ? item.label : item.insertText
            ts.beginEditing()
            ts.replaceCharacters(in: wordRange, with: text)
            ts.endEditing()
            textView.setSelectedRange(NSRange(location: wordRange.location + text.count, length: 0))
            parent.onContentChange(textView.string)
            applyHighlighting(to: textView)
            completionController.dismiss()
        }

        // MARK: Private

        /// Computes 1-based line and column numbers for the current cursor offset.
        private func cursorPosition(in textView: NSTextView) -> (line: Int, column: Int) {
            let cursorOffset = textView.selectedRange().location
            let nsString = textView.string as NSString
            let safeOffset = min(cursorOffset, nsString.length)

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
