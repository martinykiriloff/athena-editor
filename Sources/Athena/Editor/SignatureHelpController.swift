// SignatureHelpController.swift
// Athena — Non-activating NSPanel showing a call's parameters, with the active one emphasised.
// Swift 6, strict concurrency.

import AppKit

// MARK: - SignatureHelpController

@MainActor
final class SignatureHelpController: NSObject {

    var isVisible: Bool { panel.isVisible }

    private let panel: NSPanel
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let maxWidth: CGFloat = 520
    private let maxHeight: CGFloat = 160
    private let padding: CGFloat = 8

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 32),
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

    /// Shows `help` just above `screenRect` (the caret's rect in screen
    /// coordinates) — above, not below, so it never covers the line being
    /// typed or collides with the completion popup, which opens downward.
    func show(_ help: SignatureHelp, near screenRect: NSRect, fontSize: CGFloat) {
        let text = Self.attributedString(for: help, fontSize: fontSize)
        guard text.length > 0 else { dismiss(); return }

        textField.attributedStringValue = text
        let innerWidth = maxWidth - padding * 2
        let measured = text.boundingRect(
            with: NSSize(width: innerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width  = min(maxWidth,  ceil(measured.width)  + padding * 2)
        let height = min(maxHeight, ceil(measured.height) + padding * 2)
        textField.frame = NSRect(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2)

        panel.setFrame(
            NSRect(x: screenRect.minX, y: screenRect.maxY + 6, width: width, height: height),
            display: false
        )
        panel.orderFront(nil)
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    /// The signature with the active parameter in bold and full-contrast,
    /// everything else dimmed — JetBrains' own emphasis, which reads at a
    /// glance without colour.
    static func attributedString(for help: SignatureHelp, fontSize: CGFloat) -> NSAttributedString {
        let regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold    = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

        let result = NSMutableAttributedString(
            string: help.label,
            attributes: [.font: regular, .foregroundColor: NSColor.secondaryLabelColor]
        )
        if let range = help.activeParameterRange,
           range.location >= 0, NSMaxRange(range) <= result.length {
            result.addAttributes([.font: bold, .foregroundColor: NSColor.labelColor], range: range)
        }

        // The active parameter's own documentation, when the server sent it.
        if let index = help.activeParameter,
           help.parameters.indices.contains(index),
           let documentation = help.parameters[index].documentation,
           !documentation.isEmpty {
            let summary = documentation.components(separatedBy: "\n").first ?? documentation
            result.append(NSAttributedString(
                string: "\n" + summary,
                attributes: [
                    .font: NSFont.systemFont(ofSize: max(fontSize - 1, 10)),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        return result
    }

    private func buildPanel() {
        let effect = NSVisualEffectView()
        effect.material     = .menu
        effect.blendingMode = .behindWindow
        effect.state        = .active
        effect.wantsLayer   = true
        effect.layer?.cornerRadius  = 8
        effect.layer?.masksToBounds = true

        textField.backgroundColor      = .clear
        textField.isBordered           = false
        textField.isEditable           = false
        textField.isSelectable         = false
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode        = .byWordWrapping
        textField.cell?.wraps          = true

        effect.addSubview(textField)
        panel.contentView = effect
    }
}
