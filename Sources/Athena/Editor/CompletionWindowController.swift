// CompletionWindowController.swift
// Athena — Non-activating NSPanel that shows inline code completion suggestions.
// Swift 6, strict concurrency.

import AppKit

// MARK: - CompletionWindowController

@MainActor
final class CompletionWindowController: NSObject {

    // MARK: Public

    var isVisible: Bool { panel.isVisible }
    /// The popup's current on-screen frame — lets a caller (the completion
    /// documentation panel) position itself relative to it.
    var screenFrame: NSRect { panel.frame }
    var onAccept: ((CompletionItem, NSRange) -> Void)?
    /// Fired whenever the highlighted row changes — from `show`'s initial
    /// selection, `moveUp`/`moveDown`, or a mouse click on a row. Used to
    /// lazily resolve/display documentation for just the highlighted item.
    var onSelectionChange: ((CompletionItem) -> Void)?
    /// Fired from `dismiss()` — lets a caller tear down anything anchored to
    /// the popup's lifetime (the completion documentation panel).
    var onDismiss: (() -> Void)?

    // MARK: Private state

    private let panel: NSPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [CompletionItem] = []
    private(set) var wordRange: NSRange = NSRange(location: 0, length: 0)

    // MARK: Init

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 176),
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        panel.isFloatingPanel         = true
        panel.level                   = .popUpMenu
        panel.hasShadow               = true
        panel.isMovable               = false
        panel.backgroundColor         = .clear
        panel.alphaValue              = 0.98

        super.init()
        buildPanel()
    }

    // MARK: Public methods

    func show(items: [CompletionItem], wordRange: NSRange, screenRect: NSRect) {
        self.items     = items
        self.wordRange = wordRange
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        let maxRows = min(items.count, 8)
        let height  = CGFloat(maxRows) * tableView.rowHeight + 2
        let width: CGFloat = 360
        let x = screenRect.minX
        let y = screenRect.minY - height - 4  // show below cursor
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        panel.orderFront(nil)
    }

    func dismiss() {
        panel.orderOut(nil)
        items = []
        onDismiss?()
    }

    func moveDown() {
        let row = min(tableView.selectedRow + 1, items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func moveUp() {
        let row = max(tableView.selectedRow - 1, 0)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Returns true if there was a selected item to accept.
    @discardableResult
    func confirmSelection() -> Bool {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return false }
        let item = items[row]
        dismiss()
        onAccept?(item, wordRange)
        return true
    }

    // MARK: - Panel construction

    private func buildPanel() {
        // Background: frosted glass matched to editor dark theme
        let effect = NSVisualEffectView()
        effect.material        = .menu
        effect.blendingMode    = .behindWindow
        effect.state           = .active
        effect.wantsLayer      = true
        effect.layer?.cornerRadius   = 8
        effect.layer?.masksToBounds  = true

        // NSTableView
        tableView.style                  = .plain
        tableView.headerView             = nil
        tableView.focusRingType          = .none
        tableView.rowHeight              = 22
        tableView.backgroundColor        = .clear
        tableView.intercellSpacing       = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection   = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.isEditable = false
        col.minWidth   = 10
        col.maxWidth   = 10_000
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate   = self

        // Double-click accepts
        tableView.target     = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView.documentView          = tableView
        scrollView.hasVerticalScroller   = false
        scrollView.borderType            = .noBorder
        scrollView.backgroundColor       = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor .constraint(equalTo: effect.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scrollView.topAnchor    .constraint(equalTo: effect.topAnchor),
            scrollView.bottomAnchor .constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    @objc private func handleDoubleClick() {
        _ = confirmSelection()
    }

    // MARK: - Kind badge helpers

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "method":    return "M"
        case "function":  return "ƒ"
        case "class":     return "C"
        case "interface": return "I"
        case "variable":  return "v"
        case "keyword":   return "k"
        case "snippet":   return "§"
        case "property",
             "field":     return "·"
        default:          return "○"
        }
    }

    private func kindColor(_ kind: String) -> NSColor {
        switch kind {
        case "method":    return NSColor(red: 0.95, green: 0.60, blue: 0.15, alpha: 1)
        case "function":  return NSColor(red: 0.95, green: 0.70, blue: 0.25, alpha: 1)
        case "class":     return NSColor(red: 0.60, green: 0.40, blue: 0.90, alpha: 1)
        case "interface": return NSColor(red: 0.40, green: 0.70, blue: 0.90, alpha: 1)
        case "variable":  return NSColor(red: 0.30, green: 0.75, blue: 0.55, alpha: 1)
        case "keyword":   return NSColor(red: 0.90, green: 0.35, blue: 0.55, alpha: 1)
        case "snippet":   return NSColor(red: 0.80, green: 0.80, blue: 0.20, alpha: 1)
        default:          return .secondaryLabelColor
        }
    }
}

// MARK: - NSTableViewDataSource

extension CompletionWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

// MARK: - NSTableViewDelegate

extension CompletionWindowController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let ident = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell: NSTextField
        if let existing = tableView.makeView(withIdentifier: ident, owner: self) as? NSTextField {
            cell = existing
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier      = ident
            cell.font            = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.lineBreakMode   = .byTruncatingTail
            cell.drawsBackground = false
            cell.isBordered      = false
        }

        let badge   = kindLabel(item.kind)
        let detail  = item.detail.map { "  \($0)" } ?? ""
        let full    = "\(badge) \(item.label)\(detail)"

        let str = NSMutableAttributedString(string: full)
        str.addAttribute(.foregroundColor,
                         value: NSColor.labelColor,
                         range: NSRange(location: 0, length: full.count))

        // Color the kind badge
        str.addAttribute(.foregroundColor,
                         value: kindColor(item.kind),
                         range: NSRange(location: 0, length: badge.count))

        // Dim the detail suffix
        if let detailRange = full.range(of: detail),
           !detail.isEmpty,
           let r = Range(NSRange(detailRange, in: full), in: full) {
            let nsR = NSRange(r, in: full)
            str.addAttribute(.foregroundColor,
                             value: NSColor.secondaryLabelColor,
                             range: nsR)
        }

        cell.attributedStringValue = str
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NSTableRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        onSelectionChange?(items[row])
    }
}
