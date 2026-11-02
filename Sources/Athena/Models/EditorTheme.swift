// EditorTheme.swift — type-safe editor colour themes.
// Hex stored as UInt32 (trivially Sendable); NSColor computed on access.

import AppKit

// MARK: - EditorTheme

struct EditorTheme: Sendable, Equatable, Hashable, Codable {
    let id: String
    let name: String

    // Raw hex storage — avoids NSColor Sendable concerns in Swift 6.
    private let bgHex:   UInt32
    private let fgHex:   UInt32
    private let curHex:  UInt32
    private let selHex:  UInt32
    private let lineHex: UInt32
    private let kwHex:   UInt32
    private let strHex:  UInt32
    private let numHex:  UInt32
    private let cmtHex:  UInt32
    private let typHex:  UInt32
    private let fnHex:   UInt32
    private let annHex:  UInt32
    private let wsHex:   UInt32  // whitespace indicator (spaces · tabs →)
    private let diagErrHex:  UInt32  // diagnostic squiggle — error
    private let diagWarnHex: UInt32  // diagnostic squiggle — warning
    private let diagInfoHex: UInt32  // diagnostic squiggle — information/hint (drawn subtly)
    private let diffAddHex:  UInt32  // diff viewer / gutter change bar — added-line tint
    private let diffRemHex:  UInt32  // diff viewer — removed-line tint
    private let diffModHex:  UInt32  // gutter change bar — modified-line tint

    init(id: String, name: String,
         bg: UInt32, fg: UInt32, cursor: UInt32, selection: UInt32, line: UInt32,
         keyword: UInt32, string: UInt32, number: UInt32, comment: UInt32,
         type: UInt32, function: UInt32, annotation: UInt32, whitespace: UInt32,
         diagnosticError: UInt32, diagnosticWarning: UInt32, diagnosticInfo: UInt32,
         diffAdded: UInt32, diffRemoved: UInt32, diffModified: UInt32) {
        self.id      = id
        self.name    = name
        self.bgHex   = bg
        self.fgHex   = fg
        self.curHex  = cursor
        self.selHex  = selection
        self.lineHex = line
        self.kwHex   = keyword
        self.strHex  = string
        self.numHex  = number
        self.cmtHex  = comment
        self.typHex  = type
        self.fnHex   = function
        self.annHex  = annotation
        self.wsHex   = whitespace
        self.diagErrHex  = diagnosticError
        self.diagWarnHex = diagnosticWarning
        self.diagInfoHex = diagnosticInfo
        self.diffAddHex  = diffAdded
        self.diffRemHex  = diffRemoved
        self.diffModHex  = diffModified
    }

    static func == (lhs: EditorTheme, rhs: EditorTheme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Computed NSColor accessors
    var background:    NSColor { rgb(bgHex) }
    var foreground:    NSColor { rgb(fgHex) }
    var cursor:        NSColor { rgb(curHex) }
    var selection:     NSColor { rgb(selHex) }
    var lineHighlight: NSColor { rgb(lineHex) }
    var keyword:       NSColor { rgb(kwHex) }
    var string:        NSColor { rgb(strHex) }
    var number:        NSColor { rgb(numHex) }
    var comment:       NSColor { rgb(cmtHex) }
    var type:          NSColor { rgb(typHex) }
    var function:      NSColor { rgb(fnHex) }
    var annotation:    NSColor { rgb(annHex) }
    var whitespace:    NSColor { rgb(wsHex) }
    var diagnosticError:   NSColor { rgb(diagErrHex) }
    var diagnosticWarning: NSColor { rgb(diagWarnHex) }
    var diagnosticInfo:    NSColor { rgb(diagInfoHex) }
    var diffAdded:         NSColor { rgb(diffAddHex) }
    var diffRemoved:       NSColor { rgb(diffRemHex) }
    /// Gutter change-bar color for a modified line (paired removed+added
    /// within the same diff block) — distinct from `diffAdded` so a pure
    /// addition and a same-count replacement read differently in the
    /// gutter, matching VS Code's green-vs-blue gutter convention.
    var diffModified:      NSColor { rgb(diffModHex) }

    /// Darker (or, for light themes, slightly deeper) shade of the background
    /// that the island panels float on — also the activity rail and status bar.
    var frame: NSColor {
        let base = background.usingColorSpace(.sRGB) ?? background
        let amount: CGFloat = isDark ? 0.40 : 0.07
        return base.blended(withFraction: amount, of: .black) ?? base
    }

    /// Whether the editor background is dark. Drives the window's system
    /// appearance (`AppState.applyAppearance`) so the chrome — sidebar,
    /// tabs, panels, popups — matches the editor instead of staying dark
    /// around a light theme. Uses perceived luminance of the background,
    /// so imported VS Code themes classify correctly too.
    var isDark: Bool { EditorTheme.isDark(hex: bgHex) }

    /// `isDark(hex:)` for an already-materialised colour (the minimap only
    /// holds the theme's `NSColor`). Non-RGB colours count as dark.
    static func isDark(color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return true }
        return (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) < 0.5
    }

    static func isDark(hex v: UInt32) -> Bool {
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8)  & 0xFF) / 255.0
        let b = Double( v        & 0xFF) / 255.0
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.5
    }

    private func rgb(_ v: UInt32) -> NSColor {
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8)  & 0xFF) / 255.0
        let b = CGFloat( v        & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Built-in themes

extension EditorTheme {

    // Athena Dark — the One Dark palette (Atom), Athena's default.
    static let athenaDark = EditorTheme(
        id: "athena-dark", name: "Athena Dark",
        bg: 0x282C34, fg: 0xABB2BF, cursor: 0x528BFF, selection: 0x3E4451, line: 0x2C323C,
        keyword: 0xC678DD, string: 0x98C379, number: 0xD19A66,
        comment: 0x5C6370, type: 0xE5C07B, function: 0x61AFEF, annotation: 0xE06C75,
        whitespace: 0x3E4451,
        diagnosticError: 0xE06C75, diagnosticWarning: 0xD19A66, diagnosticInfo: 0x61AFEF,
        diffAdded: 0x98C379, diffRemoved: 0xE06C75, diffModified: 0x528BFF
    )

    // Athena Dracula — the JetBrains Darcula palette (IntelliJ / Rider default).
    static let athenaDracula = EditorTheme(
        id: "athena-dracula", name: "Athena Dracula",
        bg: 0x2B2B2B, fg: 0xA9B7C6, cursor: 0xBBBBBB, selection: 0x214283, line: 0x323232,
        keyword: 0xCC7832, string: 0x6A8759, number: 0x6897BB,
        comment: 0x808080, type: 0xA9B7C6, function: 0xFFC66D, annotation: 0xBBB529,
        whitespace: 0x4B5263,  // dim blue-grey — halfway between bg and comment
        diagnosticError: 0xE05252, diagnosticWarning: 0xCC9C4B, diagnosticInfo: 0x5C8BB0,
        diffAdded: 0x6A8759, diffRemoved: 0xE05252, diffModified: 0x3592C4
    )

    // Athena Light — a warm, low-glare light theme for long sessions.
    // Parchment rather than white (the background sits well below full
    // brightness, so a full-screen editor doesn't act as a lamp), an
    // ink-blue foreground instead of black, and a muted palette with no
    // saturated primaries. Every token clears the contrast floor enforced by
    // `EditorThemeAthenaLightTests` while staying quieter than a typical
    // light theme. Inspired by the Rosé Pine Dawn palette.
    static let athenaLight = EditorTheme(
        id: "athena-light", name: "Athena Light",
        bg: 0xF4EEE4, fg: 0x4B4A5E, cursor: 0x4B4A5E, selection: 0xD9D2C7, line: 0xECE5DA,
        keyword: 0x2E6B80, string: 0xA65A6E, number: 0xA8702B,
        comment: 0x968F9A, type: 0x4E8A93, function: 0x76628F, annotation: 0xC4766F,
        whitespace: 0xD9D2C7,
        diagnosticError: 0xB4637A, diagnosticWarning: 0xD89A3A, diagnosticInfo: 0x4E8A93,
        diffAdded: 0x4E8A5A, diffRemoved: 0xB4637A, diffModified: 0x2E6B80
    )

    // Athena Midnight — modern deep-blue dark. Near-black ink background with
    // soft pastel tokens (Tokyo Night family), so colour carries meaning
    // without the harsh primaries of the classic palettes. Default theme.
    static let athenaMidnight = EditorTheme(
        id: "athena-midnight", name: "Athena Midnight",
        bg: 0x11131A, fg: 0xC8CEDC, cursor: 0x7AA2FF, selection: 0x263150, line: 0x161923,
        keyword: 0xBB9AF7, string: 0x9ECE6A, number: 0xFF9E64,
        comment: 0x6B7494, type: 0x7DCFFF, function: 0x7AA2FF, annotation: 0xF7768E,
        whitespace: 0x262B3D,
        diagnosticError: 0xF7768E, diagnosticWarning: 0xE0AF68, diagnosticInfo: 0x7DCFFF,
        diffAdded: 0x9ECE6A, diffRemoved: 0xF7768E, diffModified: 0x7AA2FF
    )

    // Athena Graphite — neutral charcoal dark with Catppuccin-Mocha-style
    // pastels. Less blue than Midnight; easy on the eyes in a bright room.
    static let athenaGraphite = EditorTheme(
        id: "athena-graphite", name: "Athena Graphite",
        bg: 0x1A1B1F, fg: 0xD4D7DD, cursor: 0x89B4FA, selection: 0x2F3340, line: 0x202227,
        keyword: 0xCBA6F7, string: 0xA6E3A1, number: 0xFAB387,
        comment: 0x7A7E92, type: 0xF9E2AF, function: 0x89B4FA, annotation: 0xF38BA8,
        whitespace: 0x2F3340,
        diagnosticError: 0xF38BA8, diagnosticWarning: 0xF9E2AF, diagnosticInfo: 0x89DCEB,
        diffAdded: 0xA6E3A1, diffRemoved: 0xF38BA8, diffModified: 0x89B4FA
    )

    // Athena Daylight — clean modern light. Crisp near-white, ink foreground,
    // saturated-but-controlled accents (all clear WCAG AA on the background).
    static let athenaDaylight = EditorTheme(
        id: "athena-daylight", name: "Athena Daylight",
        bg: 0xFAFAFB, fg: 0x1F2430, cursor: 0x2D5BE3, selection: 0xD6E4FF, line: 0xF1F3F8,
        keyword: 0x7C3AED, string: 0x0E7C5A, number: 0xC2410C,
        comment: 0x6B7280, type: 0x0369A1, function: 0x2D5BE3, annotation: 0xBE185D,
        whitespace: 0xE3E6EE,
        diagnosticError: 0xDC2626, diagnosticWarning: 0xB45309, diagnosticInfo: 0x0369A1,
        diffAdded: 0x15803D, diffRemoved: 0xDC2626, diffModified: 0x2D5BE3
    )

    // High-contrast pair: pure black/white grounds, every token at WCAG AAA
    // (>= 7:1) against the background, and a selection that stays clearly
    // visible against the text.
    static let athenaHighContrastDark = EditorTheme(
        id: "athena-hc-dark", name: "Athena High Contrast Dark",
        bg: 0x000000, fg: 0xFFFFFF, cursor: 0xFFFFFF, selection: 0x1B4A9E, line: 0x1A1A1A,
        keyword: 0x6CB6FF, string: 0xF2A98A, number: 0xB5CEA8,
        comment: 0x9FD08F, type: 0x4EE0C4, function: 0xFFD866, annotation: 0xFF9DA4,
        whitespace: 0x6E6E6E,
        diagnosticError: 0xFF6B6B, diagnosticWarning: 0xFFD866, diagnosticInfo: 0x6CB6FF,
        diffAdded: 0x7EE787, diffRemoved: 0xFF7B72, diffModified: 0x6CB6FF
    )

    static let athenaHighContrastLight = EditorTheme(
        id: "athena-hc-light", name: "Athena High Contrast Light",
        bg: 0xFFFFFF, fg: 0x000000, cursor: 0x000000, selection: 0x9CC3FF, line: 0xEDEDED,
        keyword: 0x0000B8, string: 0x8A0000, number: 0x005A00,
        comment: 0x4A4A4A, type: 0x004B6B, function: 0x5B2C83, annotation: 0x9B1C1C,
        whitespace: 0x8A8A8A,
        diagnosticError: 0xB00000, diagnosticWarning: 0x7A4B00, diagnosticInfo: 0x0000B8,
        diffAdded: 0x006400, diffRemoved: 0xB00000, diffModified: 0x0000B8
    )

    static let all: [EditorTheme] = [
        .athenaMidnight, .athenaGraphite, .athenaDaylight,
        .athenaDark, .athenaDracula, .athenaLight,
        .athenaHighContrastDark, .athenaHighContrastLight,
    ]

    /// Selection fill, pushed toward the foreground when the system's
    /// Increase Contrast setting is on.
    func selectionColor(increaseContrast: Bool) -> NSColor {
        guard increaseContrast else { return selection }
        return selection.blended(withFraction: 0.35, of: foreground) ?? selection
    }

    /// Resolves a built-in theme by id. Ids persisted by earlier versions
    /// ("darcula", "one-dark", "soft-light", "github-light") map onto their
    /// renamed successors so an existing `theme.json` keeps working.
    static func named(_ id: String) -> EditorTheme {
        switch id {
        case "athena-midnight":                             return .athenaMidnight
        case "athena-graphite":                             return .athenaGraphite
        case "athena-daylight":                             return .athenaDaylight
        case "athena-dark", "one-dark":                     return .athenaDark
        case "athena-dracula", "darcula":                   return .athenaDracula
        case "athena-light", "soft-light", "github-light":  return .athenaLight
        case "athena-hc-dark":                              return .athenaHighContrastDark
        case "athena-hc-light":                             return .athenaHighContrastLight
        default:                                            return .athenaMidnight
        }
    }
}

// MARK: - Import support (plan.md item 27, "G4")

extension EditorTheme {

    /// Every color field a theme carries, keyed for à la carte overrides —
    /// used by `VSCodeThemeImporter` so it never needs access to this type's
    /// private hex storage directly; it only ever produces a
    /// `[Field: UInt32]` dictionary of what it actually found in the
    /// imported JSON.
    enum Field: Sendable, Hashable, CaseIterable {
        case background, foreground, cursor, selection, lineHighlight
        case keyword, string, number, comment, type, function, annotation
        case whitespace
        case diagnosticError, diagnosticWarning, diagnosticInfo
        case diffAdded, diffRemoved, diffModified
    }

    /// Builds a theme from `base`, overriding any fields present in
    /// `overrides`. Every field the caller didn't supply falls back to
    /// `base`'s value, so a partially-specified import (e.g. a VS Code
    /// theme with `colors` but no usable `tokenColors`) still yields a
    /// fully-defined theme instead of leaving fields undefined.
    init(id: String, name: String, base: EditorTheme, overrides: [Field: UInt32]) {
        func v(_ field: Field, _ fallback: UInt32) -> UInt32 { overrides[field] ?? fallback }
        self.init(
            id: id, name: name,
            bg: v(.background, base.bgHex), fg: v(.foreground, base.fgHex),
            cursor: v(.cursor, base.curHex), selection: v(.selection, base.selHex),
            line: v(.lineHighlight, base.lineHex),
            keyword: v(.keyword, base.kwHex), string: v(.string, base.strHex),
            number: v(.number, base.numHex), comment: v(.comment, base.cmtHex),
            type: v(.type, base.typHex), function: v(.function, base.fnHex),
            annotation: v(.annotation, base.annHex), whitespace: v(.whitespace, base.wsHex),
            diagnosticError: v(.diagnosticError, base.diagErrHex),
            diagnosticWarning: v(.diagnosticWarning, base.diagWarnHex),
            diagnosticInfo: v(.diagnosticInfo, base.diagInfoHex),
            diffAdded: v(.diffAdded, base.diffAddHex),
            diffRemoved: v(.diffRemoved, base.diffRemHex),
            diffModified: v(.diffModified, base.diffModHex)
        )
    }
}
