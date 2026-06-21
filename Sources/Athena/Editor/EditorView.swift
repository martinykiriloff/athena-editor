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

    // MARK: NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        configureTextView(textView, coordinator: context.coordinator)

        textView.string = content
        context.coordinator.applyHighlighting(to: textView)

        // Inline blame annotation label — ghost text after the cursor line.
        let blameLabel = NSTextField(labelWithString: "")
        blameLabel.isEditable     = false
        blameLabel.isBordered     = false
        blameLabel.drawsBackground = false
        blameLabel.isSelectable   = false
        blameLabel.alphaValue     = 0
        textView.addSubview(blameLabel)
        context.coordinator.blameAnnotationLabel = blameLabel

        // Expose scroll view via proxy so the minimap can drive scrolling.
        let proxy = EditorScrollProxy()
        proxy.scrollView = scrollView
        scrollProxy?.wrappedValue = proxy
        context.coordinator.scrollProxy = proxy

        // Observe live scroll notifications to feed the minimap.
        context.coordinator.installScrollObserver(on: scrollView)

        // Let the keybinding system reach this editor (find, comment, indent…).
        context.coordinator.textView = textView
        context.coordinator.installCommandObserver()
        context.coordinator.installImportClickRecognizer(on: textView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let coord = context.coordinator
        coord.parent = self          // keep fileURL and callbacks fresh on every render
        coord.currentTabSize      = tabSize
        coord.currentInsertSpaces = insertSpaces
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
        var scrollProxy: EditorScrollProxy?
        weak var textView: NSTextView?
        nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
        nonisolated(unsafe) private var commandObserver: NSObjectProtocol?
        // no mouseMonitor needed — using NSClickGestureRecognizer instead

        // Blame annotation
        var blameAnnotationLabel: NSTextField?
        var currentBlameInfo: [Int: BlameLine] = [:]

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

        // MARK: Import click — Cmd+Click anywhere on an import line opens the file

        /// Attaches an NSClickGestureRecognizer for Cmd+Click to the text view.
        /// This is far more reliable than an NSEvent local monitor because
        /// `location(in:)` gives the click point directly in the text view's own
        /// coordinate system — no window-to-view conversion required.
        func installImportClickRecognizer(on textView: NSTextView) {
            let gr = NSClickGestureRecognizer(
                target: self,
                action: #selector(handleImportClick(_:))
            )
            gr.buttonMask             = 0x1     // left button
            gr.numberOfClicksRequired = 1
            textView.addGestureRecognizer(gr)
        }

        @objc private func handleImportClick(_ gr: NSClickGestureRecognizer) {
            // Only handle Cmd+Click — modifierMask isn't bridged on NSClickGestureRecognizer
            guard NSEvent.modifierFlags.contains(.command) else { return }
            guard let tv = textView else { return }
            let point   = gr.location(in: tv)   // already in TV coordinates — no conversion needed
            let charIdx = tv.characterIndex(for: point)
            let nsStr   = tv.string as NSString
            guard charIdx != NSNotFound, charIdx < nsStr.length else { return }
            guard let path = importPath(from: tv.string, at: charIdx) else { return }
            parent.onImportClick(path, parent.fileURL)
        }

        /// Returns the last quoted string on the import/require line that contains
        /// `charIndex`. Works when clicked anywhere on the line, not just on the path.
        private func importPath(from text: String, at charIndex: Int) -> String? {
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

        private func handle(_ command: EditorCommand) {
            // Only the focused editor should react, matching VS Code semantics.
            guard let tv = textView, tv.window?.firstResponder === tv else { return }
            switch command {
            case .find:          showFindBar(tv)
            case .goToLine:      promptGoToLine(tv)
            case .toggleComment: toggleComment(tv)
            case .indent:        shiftIndent(tv, indent: true)
            case .outdent:       shiftIndent(tv, indent: false)
            }
        }

        private var indentUnit: String {
            currentInsertSpaces ? String(repeating: " ", count: max(1, currentTabSize)) : "\t"
        }

        private func showFindBar(_ tv: NSTextView) {
            tv.usesFindBar = true
            let sender = NSMenuItem()
            sender.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
            tv.performTextFinderAction(sender)
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
                 .rust, .go, .css:                return "//"
            case .json, .html, .markdown, .plaintext: return ""
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
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onContentChange(textView.string)
            // Re-colour after every edit so tokens track the user's keystrokes.
            applyHighlighting(to: textView)
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
