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
    var onCursorMove: (Int, Int) -> Void = { _, _ in }
    var onContentChange: (String) -> Void = { _ in }
    /// Called whenever the scroll position changes. (fraction 0‥1, visible ratio 0‥1)
    var onScrollChange: (Double, Double) -> Void = { _, _ in }
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

        // Expose scroll view via proxy so the minimap can drive scrolling.
        let proxy = EditorScrollProxy()
        proxy.scrollView = scrollView
        scrollProxy?.wrappedValue = proxy
        context.coordinator.scrollProxy = proxy

        // Observe live scroll notifications to feed the minimap.
        context.coordinator.installScrollObserver(on: scrollView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let coord = context.coordinator
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
        var scrollProxy: EditorScrollProxy?
        nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

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
