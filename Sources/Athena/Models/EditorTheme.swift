// EditorTheme.swift — type-safe editor colour themes.
// Hex stored as UInt32 (trivially Sendable); NSColor computed on access.

import AppKit

// MARK: - EditorTheme

struct EditorTheme: Sendable, Equatable, Hashable {
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
    private let diffAddHex:  UInt32  // diff viewer — added-line gutter/background tint
    private let diffRemHex:  UInt32  // diff viewer — removed-line gutter/background tint

    init(id: String, name: String,
         bg: UInt32, fg: UInt32, cursor: UInt32, selection: UInt32, line: UInt32,
         keyword: UInt32, string: UInt32, number: UInt32, comment: UInt32,
         type: UInt32, function: UInt32, annotation: UInt32, whitespace: UInt32,
         diagnosticError: UInt32, diagnosticWarning: UInt32, diagnosticInfo: UInt32,
         diffAdded: UInt32, diffRemoved: UInt32) {
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
        diffAdded: 0x6A8759, diffRemoved: 0xE05252
    )

    // One Dark — Atom-inspired dark theme.
    static let oneDark = EditorTheme(
        id: "one-dark", name: "One Dark",
        bg: 0x282C34, fg: 0xABB2BF, cursor: 0x528BFF, selection: 0x3E4451, line: 0x2C323C,
        keyword: 0xC678DD, string: 0x98C379, number: 0xD19A66,
        comment: 0x5C6370, type: 0xE5C07B, function: 0x61AFEF, annotation: 0xE06C75,
        whitespace: 0x3E4451,
        diagnosticError: 0xE06C75, diagnosticWarning: 0xD19A66, diagnosticInfo: 0x61AFEF,
        diffAdded: 0x98C379, diffRemoved: 0xE06C75
    )

    // GitHub Light — clean light theme.
    static let githubLight = EditorTheme(
        id: "github-light", name: "GitHub Light",
        bg: 0xFFFFFF, fg: 0x24292E, cursor: 0x24292E, selection: 0xC8D1F0, line: 0xF6F8FA,
        keyword: 0xD73A49, string: 0x032F62, number: 0x005CC5,
        comment: 0x6A737D, type: 0x6F42C1, function: 0x6F42C1, annotation: 0x005CC5,
        whitespace: 0xD0D7DE,
        diagnosticError: 0xD73A49, diagnosticWarning: 0xB08800, diagnosticInfo: 0x005CC5,
        diffAdded: 0x28A745, diffRemoved: 0xD73A49
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
