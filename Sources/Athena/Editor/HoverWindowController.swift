// HoverWindowController.swift
// Athena — Non-activating NSPanel that shows LSP hover information (type info + docs) near the cursor.
// Swift 6, strict concurrency.

import AppKit

// MARK: - HoverWindowController

@MainActor
final class HoverWindowController: NSObject {

    // MARK: Public

    var isVisible: Bool { panel.isVisible }

    // MARK: Private state

    private let panel: NSPanel
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let maxWidth: CGFloat = 420
    private let maxHeight: CGFloat = 280
    private let padding: CGFloat = 10

    // MARK: Init

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        panel.isFloatingPanel = true
        panel.level           = .popUpMenu
        panel.hasShadow       = true
        panel.isMovable       = false
        panel.backgroundColor = .clear
        panel.alphaValue      = 0.98

        super.init()
        buildPanel()
    }

    // MARK: Public methods

    /// Shows `text` in a floating panel positioned just above `screenRect`
    /// (the glyph rect of the hovered character, in screen coordinates) —
    /// mirrors `CompletionWindowController.show`'s "below/above the anchor"
    /// placement.
    func show(text: String, near screenRect: NSRect) {
        let innerWidth = maxWidth - padding * 2
        let measured    = measure(text, maxWidth: innerWidth)
        let width  = min(maxWidth,  measured.width  + padding * 2)
        let height = min(maxHeight, measured.height + padding * 2)

        textField.stringValue = text
        textField.frame = NSRect(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2)

        let x = screenRect.minX
        let y = screenRect.minY - height - 4  // show below the hovered glyph
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        panel.orderFront(nil)
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    // MARK: - Panel construction

    private func buildPanel() {
        // Background: frosted glass matched to editor dark theme, matching
        // CompletionWindowController's panel chrome.
        let effect = NSVisualEffectView()
        effect.material     = .menu
        effect.blendingMode = .behindWindow
        effect.state        = .active
        effect.wantsLayer   = true
        effect.layer?.cornerRadius  = 8
        effect.layer?.masksToBounds = true

        textField.font                 = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.textColor            = .labelColor
        textField.backgroundColor      = .clear
        textField.isBordered           = false
        textField.isEditable           = false
        textField.isSelectable         = true
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode        = .byWordWrapping
        textField.cell?.wraps          = true

        effect.addSubview(textField)
        panel.contentView = effect
    }

    /// Computes the wrapped size of `text` at `maxWidth`, using the same
    /// font as the visible label.
    private func measure(_ text: String, maxWidth: CGFloat) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: textField.font as Any]
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return NSSize(width: ceil(bounding.width), height: ceil(bounding.height))
    }
}
