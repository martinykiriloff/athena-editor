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

    private func rgb(_ v: UInt32) -> NSColor {
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8)  & 0xFF) / 255.0
        let b = CGFloat( v        & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Built-in themes

extension EditorTheme {

    // Exact JetBrains Darcula palette — IntelliJ / Rider default dark theme.
    static let darcula = EditorTheme(
        id: "darcula", name: "Darcula",
        bg: 0x2B2B2B, fg: 0xA9B7C6, cursor: 0xBBBBBB, selection: 0x214283, line: 0x323232,
        keyword: 0xCC7832, string: 0x6A8759, number: 0x6897BB,
        comment: 0x808080, type: 0xA9B7C6, function: 0xFFC66D, annotation: 0xBBB529,
        whitespace: 0x4B5263,  // dim blue-grey — halfway between bg and comment
        diagnosticError: 0xE05252, diagnosticWarning: 0xCC9C4B, diagnosticInfo: 0x5C8BB0,
        diffAdded: 0x6A8759, diffRemoved: 0xE05252, diffModified: 0x3592C4
    )

    // One Dark — Atom-inspired dark theme.
    static let oneDark = EditorTheme(
        id: "one-dark", name: "One Dark",
        bg: 0x282C34, fg: 0xABB2BF, cursor: 0x528BFF, selection: 0x3E4451, line: 0x2C323C,
        keyword: 0xC678DD, string: 0x98C379, number: 0xD19A66,
        comment: 0x5C6370, type: 0xE5C07B, function: 0x61AFEF, annotation: 0xE06C75,
        whitespace: 0x3E4451,
        diagnosticError: 0xE06C75, diagnosticWarning: 0xD19A66, diagnosticInfo: 0x61AFEF,
        diffAdded: 0x98C379, diffRemoved: 0xE06C75, diffModified: 0x528BFF
    )

    // GitHub Light — clean light theme.
    static let githubLight = EditorTheme(
        id: "github-light", name: "GitHub Light",
        bg: 0xFFFFFF, fg: 0x24292E, cursor: 0x24292E, selection: 0xC8D1F0, line: 0xF6F8FA,
        keyword: 0xD73A49, string: 0x032F62, number: 0x005CC5,
        comment: 0x6A737D, type: 0x6F42C1, function: 0x6F42C1, annotation: 0x005CC5,
        whitespace: 0xD0D7DE,
        diagnosticError: 0xD73A49, diagnosticWarning: 0xB08800, diagnosticInfo: 0x005CC5,
        diffAdded: 0x28A745, diffRemoved: 0xD73A49, diffModified: 0x0366D6
    )

    static let all: [EditorTheme] = [.darcula, .oneDark, .githubLight]

    static func named(_ id: String) -> EditorTheme {
        switch id {
        case "darcula":      return .darcula
        case "one-dark":     return .oneDark
        case "github-light": return .githubLight
        default:             return .darcula
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
