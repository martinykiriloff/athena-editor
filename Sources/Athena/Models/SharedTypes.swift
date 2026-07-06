// SharedTypes.swift
// Athena — shared domain types used across the entire application.
// Swift 6, strict concurrency.

import Foundation
import SwiftUI

// MARK: - Panels

enum SidebarPanel: String, Sendable, CaseIterable {
    case files, git, search, database, sfcc, npm, debug, outline
}

// MARK: - Debugger

enum DebugState: Sendable, Equatable {
    case idle
    case launching
    case running
    case paused(reason: String)
    case stopped
}

struct DebugBreakpoint: Identifiable, Sendable {
    let id: UUID = UUID()
    let filePath: String
    let line: Int
    var isVerified: Bool = false
}

struct DebugStackFrame: Identifiable, Sendable {
    let id: Int
    let name: String
    let sourceURL: URL?
    let line: Int
    let column: Int
}

struct DebugVariable: Identifiable, Sendable {
    let id: UUID = UUID()
    let name: String
    let value: String
    let type: String?
    let variablesReference: Int
}

/// Result of a DAP/CDP `evaluate` request (plan.md item 24) — shared by
/// watch expressions and the debug console REPL, both of which just want
/// "expression in, display string + type out" against a specific frame.
struct DAPEvaluateResult: Sendable {
    let result: String
    let type: String?
    let variablesReference: Int
}

/// A user-defined watch expression (plan.md item 24) that persists across
/// debug steps and re-evaluates every time the debugger pauses. `lastError`
/// is set (and `lastValue`/`lastType` cleared) when evaluation fails — e.g.
/// the expression references a variable out of scope for the current frame
/// — so the row can show an inline error instead of crashing or spamming
/// `AppState.statusMessage`.
struct WatchExpression: Identifiable, Sendable {
    let id: UUID = UUID()
    var expression: String
    var lastValue: String? = nil
    var lastType: String? = nil
    var lastError: String? = nil

    /// Pure "add" helper — trims whitespace, ignores a blank expression.
    /// Extracted the same way `TabModel.nextActiveId`/`TerminalSession.nextActiveId`
    /// pull their close-tab decision out into a testable free function, so the
    /// list-mutation logic doesn't need a live `AppState`/`DebugService` to test.
    static func appending(_ raw: String, to list: [WatchExpression]) -> [WatchExpression] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        var result = list
        result.append(WatchExpression(expression: trimmed))
        return result
    }

    /// Pure "remove" helper.
    static func removing(_ id: UUID, from list: [WatchExpression]) -> [WatchExpression] {
        list.filter { $0.id != id }
    }

    /// Applies a batch of freshly evaluated results (keyed by expression id)
    /// back onto `list` in place — expressions with no entry in `results`
    /// (shouldn't happen in practice, but keeps this total) pass through
    /// untouched rather than losing their last-known value.
    static func applying(
        _ results: [UUID: WatchEvaluationOutcome],
        to list: [WatchExpression]
    ) -> [WatchExpression] {
        list.map { expr in
            guard let outcome = results[expr.id] else { return expr }
            var updated = expr
            switch outcome {
            case .success(let r):
                updated.lastValue = r.result
                updated.lastType  = r.type
                updated.lastError = nil
            case .failure(let message):
                updated.lastValue = nil
                updated.lastType  = nil
                updated.lastError = message
            }
            return updated
        }
    }
}

/// Outcome of evaluating one watch expression. A plain enum rather than
/// Swift's `Result` — the failure case is just a display message, not an
/// `Error`, so there's no reason to require `Error` conformance of it.
enum WatchEvaluationOutcome: Sendable {
    case success(DAPEvaluateResult)
    case failure(String)
}

/// One transcript entry in the debug console REPL (plan.md item 24) —
/// the expression the user typed and its evaluated result (or error text).
struct DebugConsoleEntry: Identifiable, Sendable {
    let id: UUID = UUID()
    let expression: String
    let result: String
    let isError: Bool
}

struct LaunchConfig: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var type: String       // "lldb", "python", "node-cdp", "chrome", "nextjs"
    var request: String    // "launch" or "attach"
    var name: String
    var program: String    // path, ${file}, or "" for browser configs
    var args: [String] = []
    var env: [String: String] = [:]
    var cwd: String = "${workspaceFolder}"
    var stopOnEntry: Bool = false
    var debugPort: Int? = nil    // CDP port: 9229 for Node, 9222 for Chrome
    var url: String? = nil       // Browser page URL to open / attach to
}

// MARK: - Database connections

enum DBType: String, Codable, Sendable, CaseIterable {
    case postgresql = "PostgreSQL"
    case mongodb    = "MongoDB"
    case mysql      = "MySQL"
    case oracle     = "Oracle"
    case mariadb    = "MariaDB"

    var defaultPort: Int {
        switch self {
        case .postgresql: return 5432
        case .mongodb:    return 27017
        case .mysql:      return 3306
        case .oracle:     return 1521
        case .mariadb:    return 3306
        }
    }

    var sfSymbol: String {
        switch self {
        case .postgresql: return "elephant"          // closest available
        case .mongodb:    return "leaf.fill"
        case .mysql:      return "cylinder.fill"
        case .oracle:     return "building.columns.fill"
        case .mariadb:    return "cylinder.split.1x2.fill"
        }
    }

    var accentHex: UInt32 {
        switch self {
        case .postgresql: return 0x336791
        case .mongodb:    return 0x4DB33D
        case .mysql:      return 0x00758F
        case .oracle:     return 0xF80000
        case .mariadb:    return 0xC0765A
        }
    }
}

struct DBConnection: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var name: String
    var type: DBType
    var host: String        = "localhost"
    var port: Int
    var database: String    = ""
    var username: String    = ""
    var password: String    = ""   // never persisted to disk; lives in Keychain (see KeychainService.dbPassword)
    var isConnected: Bool   = false

    init(name: String, type: DBType) {
        self.name = name
        self.type = type
        self.port = type.defaultPort
    }
}

// `password` is deliberately excluded from the on-disk JSON; it round-trips
// through the Keychain instead. Decoding still reads a legacy plaintext
// password if present so existing settings files migrate transparently.
extension DBConnection {
    private enum CodingKeys: String, CodingKey {
        case id, name, type, host, port, database, username, password, isConnected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self, forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        type        = try c.decode(DBType.self, forKey: .type)
        host        = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port        = try c.decode(Int.self, forKey: .port)
        database    = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        username    = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password    = try c.decodeIfPresent(String.self, forKey: .password) ?? ""  // legacy only
        isConnected = try c.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,          forKey: .id)
        try c.encode(name,        forKey: .name)
        try c.encode(type,        forKey: .type)
        try c.encode(host,        forKey: .host)
        try c.encode(port,        forKey: .port)
        try c.encode(database,    forKey: .database)
        try c.encode(username,    forKey: .username)
        // password intentionally omitted — stored in the Keychain
        try c.encode(isConnected, forKey: .isConnected)
    }
}

enum BottomPanel: String, Sendable, CaseIterable {
    case terminal, scripts, output, problems, chat, sfcclogs, references, debugConsole
}

// MARK: - Language

enum Language: String, Sendable, CaseIterable {
    case swift
    case typescript
    case javascript
    case python
    case rust
    case go
    case json
    case css
    case html
    case isml
    case ds
    case markdown
    case image
    case plaintext

    /// Returns the file extensions associated with this language.
    var fileExtensions: [String] {
        switch self {
        case .swift:      return ["swift"]
        case .typescript: return ["ts", "tsx"]
        case .javascript: return ["js", "jsx", "mjs"]
        case .python:     return ["py"]
        case .rust:       return ["rs"]
        case .go:         return ["go"]
        case .json:       return ["json", "jsonc"]
        case .css:        return ["css", "scss", "less"]
        case .html:       return ["html", "htm"]
        case .isml:       return ["isml"]
        case .ds:         return ["ds"]
        case .markdown:   return ["md", "markdown"]
        // Formats NSImage loads natively (plan.md item 26, "G1") — opening one
        // of these shows `ImagePreviewView` instead of the plain-text editor.
        // `svg` deliberately included per the task spec even though it's also
        // XML source; there is no "open as text" escape hatch yet.
        case .image:      return ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "tif"]
        case .plaintext:  return []
        }
    }

    /// Detects the language for a given file URL based on its path extension.
    static func detect(from url: URL) -> Language {
        let ext = url.pathExtension.lowercased()
        for language in Language.allCases {
            if language.fileExtensions.contains(ext) {
                return language
            }
        }
        return .plaintext
    }
}

// MARK: - SFCC / Demandware

struct SFCCConnection: Identifiable, Codable, Sendable {
    var id: UUID          = UUID()
    var name: String
    var hostname: String       // e.g. "dev01-abc.demandware.net"
    var username: String       = ""
    var password: String       = ""   // never persisted to disk; lives in Keychain (see KeychainService.sfccPassword)
    var codeVersion: String    = "version1"
    var cartridgesPath: String = "cartridges"  // relative or absolute
    var isActive: Bool         = false
}

// `password` is excluded from the on-disk JSON and stored in the Keychain.
// Decoding still reads a legacy plaintext password so existing settings
// files migrate transparently on first load.
extension SFCCConnection {
    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, username, password, codeVersion, cartridgesPath, isActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name           = try c.decode(String.self, forKey: .name)
        hostname       = try c.decode(String.self, forKey: .hostname)
        username       = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password       = try c.decodeIfPresent(String.self, forKey: .password) ?? ""  // legacy only
        codeVersion    = try c.decodeIfPresent(String.self, forKey: .codeVersion) ?? "version1"
        cartridgesPath = try c.decodeIfPresent(String.self, forKey: .cartridgesPath) ?? "cartridges"
        isActive       = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,             forKey: .id)
        try c.encode(name,           forKey: .name)
        try c.encode(hostname,       forKey: .hostname)
        try c.encode(username,       forKey: .username)
        // password intentionally omitted — stored in the Keychain
        try c.encode(codeVersion,    forKey: .codeVersion)
        try c.encode(cartridgesPath, forKey: .cartridgesPath)
        try c.encode(isActive,       forKey: .isActive)
    }
}

// MARK: - Diagnostics

enum DiagnosticSeverity: Sendable, Equatable {
    case error, warning, information, hint
}

// MARK: - Claude accounts

struct ClaudeAccount: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let command: String   // CLI binary name: "claude" or "claude-work"

    static let personal = ClaudeAccount(id: "personal", name: "Personal", command: "claude")
    static let work     = ClaudeAccount(id: "work",     name: "Work",     command: "claude-work")
    static let all: [ClaudeAccount] = [.personal, .work]
}

struct ClaudeMessage: Identifiable, Sendable {
    let id: UUID = UUID()
    var role: ChatRole
    var content: String
    var isStreaming: Bool = false
}

// MARK: - Chat

enum ChatRole: Sendable {
    case user, assistant
}

// MARK: - Editor commands

/// Editor-level actions dispatched from the keybinding system to the active
/// text view (which can't be reached directly from AppState).
enum EditorCommand: Sendable {
    case find
    case findAndReplace
    case goToLine
    case toggleComment
    case indent
    case outdent
    case selectNextOccurrence
    case findReferences
    case renameSymbol
    case moveLineUp
    case moveLineDown
    case copyLineUp
    case copyLineDown
    case deleteLine
}

// MARK: - Workspace & Files

struct WorkspaceModel: Identifiable, Sendable {
    let id = UUID()
    var rootURL: URL

    var name: String { rootURL.lastPathComponent }
}

struct FileNode: Identifiable, Sendable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isDirectory: Bool
    var children: [FileNode]?
    var isExpanded: Bool = false
    var depth: Int = 0
}

// MARK: - Tabs

struct TabModel: Identifiable, Sendable {
    let id = UUID()
    var fileURL: URL?
    var title: String
    var content: String = ""
    var isDirty: Bool = false
    var language: Language = .plaintext
    var cursorLine: Int = 1
    var cursorColumn: Int = 1
    /// Set when the file backing this tab changed on disk while the tab had
    /// unsaved edits (so the silent-reload path in `AppState` couldn't just
    /// overwrite it). Drives the "file changed on disk" banner in
    /// `CodeEditorView`.
    var externallyModified: Bool = false
    /// Markdown-only Source/Preview toggle (plan.md item 26, "G2") — kept on
    /// `TabModel` rather than local `@State` in `CodeEditorView` so it
    /// persists per-tab and doesn't bleed onto the next markdown tab
    /// switched into (a plain `@State` in that view isn't reset by a tab
    /// switch, since the view's identity in the SwiftUI tree doesn't change
    /// when `AppState.activeTab(in:)` swaps out from under it — see
    /// `EditorPaneView.body`). Ignored for every non-markdown language.
    var isMarkdownPreview: Bool = false

    static func untitled() -> TabModel {
        TabModel(title: "Untitled")
    }
}

extension TabModel {
    /// Computes the tab that should become active after closing `closedId`
    /// within `tabs` — prefer the tab now at the same index, falling back to
    /// the last remaining one; `nil` once none remain. Returns
    /// `previousActiveId` unchanged when the closed tab wasn't the active
    /// one. Mirrors `TerminalSession.nextActiveId`'s rule exactly; shared by
    /// both the primary and secondary editor group's close-tab logic
    /// (plan.md item 22) so "which tab activates next" can't drift between
    /// the two panes.
    static func nextActiveId(
        afterClosing closedId: UUID,
        in tabs: [TabModel],
        previousActiveId: UUID?
    ) -> UUID? {
        guard previousActiveId == closedId else { return previousActiveId }
        guard let index = tabs.firstIndex(where: { $0.id == closedId }) else {
            return previousActiveId
        }
        var remaining = tabs
        remaining.remove(at: index)
        guard !remaining.isEmpty else { return nil }
        let newIndex = min(index, remaining.count - 1)
        return remaining[newIndex].id
    }
}

// MARK: - Editor Groups (Split Editor)

/// Identifies one of the (at most two) editor panes once the editor is split
/// (plan.md item 22, "Split Editor Right"). `.primary` is always present —
/// it's `AppState.openTabs`/`activeTabId` directly, kept as top-level fields
/// rather than wrapped in an `EditorGroup` to minimize disruption to the
/// dozens of call sites already written against "the" active tab from before
/// split editors existed. `.secondary` only exists while
/// `AppState.secondaryGroup != nil`.
enum EditorGroupSide: Sendable, Equatable {
    case primary
    case secondary

    /// The other side — used to check whether a file being closed in one
    /// group is still open as an independent tab in the other before
    /// tearing down its LSP/file-watch/diagnostics state (`AppState.closeTab`).
    var other: EditorGroupSide {
        switch self {
        case .primary:   return .secondary
        case .secondary: return .primary
        }
    }
}

/// The secondary editor pane's tab state (plan.md item 22). `nil` on
/// `AppState.secondaryGroup` means "not split" — matching how `debugState`/
/// other optional-feature state already models "feature not active" in this
/// codebase — and single-pane behavior must be identical to today in that
/// case. The primary pane deliberately isn't wrapped in this same type; see
/// `EditorGroupSide`'s doc comment.
struct EditorGroup: Identifiable, Sendable {
    let id: UUID = UUID()
    var tabs: [TabModel] = []
    var activeTabId: UUID?

    var activeTab: TabModel? {
        tabs.first { $0.id == activeTabId }
    }
}

// MARK: - Terminal Sessions

/// One tab in the integrated terminal panel (plan.md item 21). SwiftTerm's
/// `LocalProcessTerminalView` has no notion of running more than one shell
/// per instance, so each session needs its own view instance — this model
/// just carries the identity/title/shell that view is bound to, letting
/// SwiftUI diff a list of sessions the same way `openTabs`/`TabModel`
/// already works for editor tabs.
struct TerminalSession: Identifiable, Sendable {
    let id: UUID = UUID()
    var title: String
    let shell: String
}

extension TerminalSession {
    /// Computes the session that should become active after closing
    /// `closedId`, mirroring `AppState.closeTab`'s adjacent-selection rule:
    /// prefer the session now at the same index, falling back to the last
    /// remaining one; `nil` once none remain. Returns `previousActiveId`
    /// unchanged when the closed session wasn't the active one.
    static func nextActiveId(
        afterClosing closedId: UUID,
        in sessions: [TerminalSession],
        previousActiveId: UUID?
    ) -> UUID? {
        guard previousActiveId == closedId else { return previousActiveId }
        guard let index = sessions.firstIndex(where: { $0.id == closedId }) else {
            return previousActiveId
        }
        var remaining = sessions
        remaining.remove(at: index)
        guard !remaining.isEmpty else { return nil }
        let newIndex = min(index, remaining.count - 1)
        return remaining[newIndex].id
    }
}

// MARK: - Session Restore

/// A single persisted tab within a workspace session — enough to reopen the
/// file via `AppState.openFile(_:)` and restore its last cursor position.
struct SessionTab: Codable, Sendable {
    var path: String
    var cursorLine: Int
    var cursorColumn: Int
}

/// The persisted tab layout for one workspace root. Stored keyed by the
/// workspace's absolute path inside the `"workspaceSessions"` settings entry,
/// so each project folder remembers its own tabs independently of any other.
struct WorkspaceSession: Codable, Sendable {
    var tabs: [SessionTab] = []
    var activePath: String?
}

// MARK: - Git

struct GitStatus: Sendable {
    var branch: String = ""
    var staged: [GitFileChange] = []
    var unstaged: [GitFileChange] = []
    var untracked: [GitFileChange] = []
    /// Files `git status` reports as unmerged (`UU`/`AA`/`DD`/… porcelain
    /// codes) — an active, unresolved merge/rebase conflict. Kept separate
    /// from `staged`/`unstaged` rather than landing in (or duplicated
    /// across) both, since "conflicted" isn't really either bucket. Feeds
    /// the editor's merge-conflict resolution UI (plan.md item 23, "D5") as
    /// the gate against a false positive on a file that merely *contains*
    /// the literal marker strings for an unrelated reason.
    var conflicted: [GitFileChange] = []
    var ahead: Int = 0
    var behind: Int = 0

    var isClean: Bool {
        staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicted.isEmpty
    }
}

struct GitFileChange: Identifiable, Sendable {
    let id = UUID()
    var path: String
    var status: String
}

struct GitCommit: Identifiable, Sendable {
    let id = UUID()
    var hash: String
    var shortHash: String
    var message: String
    var author: String
    var date: Date
}

/// One entry from `git branch -a`, parsed by `GitService.parseBranches(_:)`.
/// Powers the branch-switcher menu in `StatusBarView` (plan.md item 20, "D3").
struct GitBranch: Identifiable, Sendable, Equatable {
    var name: String
    var isCurrent: Bool
    var isRemote: Bool

    /// `name` alone isn't a stable `ForEach` identity across the local and
    /// remote lists (a remote-tracking branch's name already includes its
    /// remote, e.g. `"origin/main"`, but nothing rules out a local branch
    /// sharing that same string), so identity also folds in `isRemote`.
    var id: String { (isRemote ? "remote:" : "local:") + name }
}

// MARK: - Git Blame

struct BlameLine: Sendable, Equatable {
    var hash: String
    var author: String
    var date: Date
    var summary: String
}

// MARK: - Search

struct SearchResult: Identifiable, Sendable {
    let id = UUID()
    var filePath: String
    var lineNumber: Int
    var lineContent: String
    var matchRange: NSRange
}

/// Shared literal/regex match-and-replace engine used by both the in-file
/// find/replace bar (`FindReplaceController`) and workspace-wide "Replace
/// All" (`AppState.replaceAllInWorkspace`), so both apply identical
/// case-sensitivity, whole-word, and regex semantics.
struct TextSearchMatcher: Sendable {
    var query: String
    var isRegex: Bool
    var caseSensitive: Bool
    var wholeWord: Bool

    /// Fails when `query` is empty, or (in regex mode) doesn't compile.
    init?(query: String, isRegex: Bool, caseSensitive: Bool, wholeWord: Bool) {
        guard !query.isEmpty else { return nil }
        self.query = query
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        guard Self.compile(query: query, isRegex: isRegex, caseSensitive: caseSensitive, wholeWord: wholeWord) != nil
        else { return nil }
    }

    /// All non-overlapping match ranges in `text`, in order.
    func matches(in text: String) -> [NSRange] {
        guard let re = Self.compile(query: query, isRegex: isRegex, caseSensitive: caseSensitive, wholeWord: wholeWord)
        else { return [] }
        let full = NSRange(location: 0, length: (text as NSString).length)
        return re.matches(in: text, range: full).map(\.range)
    }

    /// Replacement text for one already-located match — honors regex
    /// capture-group references (`$1`) when `isRegex` is true; substitutes
    /// `replacement` literally otherwise.
    func replacementText(forMatchIn text: String, range: NSRange, replacement: String) -> String {
        guard isRegex,
              let re = Self.compile(query: query, isRegex: isRegex, caseSensitive: caseSensitive, wholeWord: wholeWord),
              let match = re.firstMatch(in: text, range: range)
        else { return replacement }
        return re.replacementString(for: match, in: text, offset: 0, template: replacement)
    }

    /// Replaces every match in `text`. Returns the original text and a count
    /// of 0 when there are no matches.
    func replacingAll(in text: String, with replacement: String) -> (result: String, count: Int) {
        guard let re = Self.compile(query: query, isRegex: isRegex, caseSensitive: caseSensitive, wholeWord: wholeWord)
        else { return (text, 0) }
        let full = NSRange(location: 0, length: (text as NSString).length)
        let found = re.matches(in: text, range: full)
        guard !found.isEmpty else { return (text, 0) }

        // Regex mode honors `$1`-style templates; literal mode treats the
        // replacement as plain text (escaped so it can't be misread as one).
        let template = isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        let mutable = NSMutableString(string: text)
        // Apply back-to-front so earlier ranges stay valid as later ones shrink/grow.
        for match in found.reversed() {
            let piece = re.replacementString(for: match, in: text, offset: 0, template: template)
            mutable.replaceCharacters(in: match.range, with: piece)
        }
        return (mutable as String, found.count)
    }

    private static func compile(
        query: String, isRegex: Bool, caseSensitive: Bool, wholeWord: Bool
    ) -> NSRegularExpression? {
        var pattern = isRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }
}

// MARK: - Diagnostics

struct Diagnostic: Identifiable, Sendable, Equatable {
    let id = UUID()
    var fileURL: URL
    var line: Int
    var column: Int
    var message: String
    var severity: DiagnosticSeverity

    /// Compares by content, not `id` — a fresh `publishDiagnostics` batch
    /// reconstructs every `Diagnostic` with a new random `id` even when
    /// nothing actually changed, so `EditorView`'s "did the diagnostics for
    /// this file change" gate (used to decide whether to recompute squiggle
    /// underlines) needs value equality here, not identity.
    static func == (lhs: Diagnostic, rhs: Diagnostic) -> Bool {
        lhs.fileURL == rhs.fileURL && lhs.line == rhs.line && lhs.column == rhs.column
            && lhs.message == rhs.message && lhs.severity == rhs.severity
    }
}

// MARK: - Chat

struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    var role: ChatRole
    var content: String
}

// MARK: - Completions

struct CompletionItem: Identifiable, Sendable {
    let id = UUID()
    var label: String
    var kind: String
    var detail: String?
    var insertText: String
}

// MARK: - Go to Definition

/// A single `textDocument/definition` result. `line`/`character` are
/// 1-based, matching this app's convention (LSP positions are 0-based over
/// the wire — see `LSPManager.parseDiagnostics` for the same conversion).
struct DefinitionLocation: Sendable, Equatable {
    var fileURL: URL
    var line: Int
    var character: Int
}

/// A single "jump to this location" request originating outside the
/// editor's own view hierarchy (e.g. a "Find All References" panel row
/// click, routed via `AppState.pendingNavigationTarget`). Wraps
/// `DefinitionLocation` with a unique `id` so
/// `EditorView.Coordinator.consumePendingNavigation` can tell "already
/// consumed this exact request" (dedup against redundant `updateNSView`
/// calls before the request's async clear lands) apart from "the user asked
/// to jump here again" (same location, but a new request, e.g. clicking the
/// same reference twice) — value equality on `DefinitionLocation` alone
/// can't distinguish those two cases.
struct NavigationRequest: Sendable, Equatable {
    var id: UUID
    var location: DefinitionLocation
}

// MARK: - Document Symbols (Go to Symbol / Outline / Breadcrumbs)

/// One symbol from a `textDocument/documentSymbol` response, normalized from
/// either shape the LSP spec allows — hierarchical `DocumentSymbol` (nested
/// `children`) or the older, flat `SymbolInformation` (`location` instead of
/// `range`/`selectionRange`, never nested) — see
/// `LSPManager.documentSymbols(fileURL:)`. `line`/`character` are 1-based,
/// this app's convention, and mark the symbol's *selection range* (the name
/// token itself) — where "jump to symbol" lands, matching VS Code. `kind` is
/// kept as the raw LSP `SymbolKind` integer rather than a Swift enum case
/// (mirroring how `LSPManager.completionKindName` maps completion kinds) —
/// `iconName` below is the readable lookup built on top of it.
struct DocumentSymbol: Identifiable, Sendable, Equatable {
    let id = UUID()
    var name: String
    var kind: Int
    var line: Int
    var character: Int
    /// 1-based, inclusive start/end line of the symbol's full extent (e.g. a
    /// function's whole body, not just its name) — used by
    /// `AppState.breadcrumbPath` to test whether the cursor sits inside this
    /// symbol.
    var rangeStartLine: Int
    var rangeEndLine: Int
    /// `nil` for leaf symbols (no nested children) rather than an empty
    /// array, so SwiftUI's `List(_:children:)`/`OutlineGroup` (used by
    /// `OutlineView`) doesn't draw a disclosure triangle that expands to
    /// nothing.
    var children: [DocumentSymbol]?

    /// SF Symbol name for `kind`, one per LSP `SymbolKind` (1…26). Falls back
    /// to a generic glyph for anything outside that range.
    var iconName: String {
        switch kind {
        case 1:  return "doc.text"                        // File
        case 2:  return "shippingbox"                      // Module
        case 3:  return "n.square"                         // Namespace
        case 4:  return "shippingbox.fill"                 // Package
        case 5:  return "c.square.fill"                    // Class
        case 6:  return "m.square.fill"                    // Method
        case 7:  return "p.square.fill"                    // Property
        case 8:  return "f.square"                         // Field
        case 9:  return "hammer.fill"                      // Constructor
        case 10: return "e.square.fill"                    // Enum
        case 11: return "i.square.fill"                    // Interface
        case 12: return "function"                         // Function
        case 13: return "v.square"                         // Variable
        case 14: return "v.square.fill"                    // Constant
        case 15: return "textformat.abc"                   // String
        case 16: return "number"                            // Number
        case 17: return "checkmark.square"                  // Boolean
        case 18: return "square.stack"                      // Array
        case 19: return "cube"                              // Object
        case 20: return "key.fill"                          // Key
        case 21: return "circle.slash"                      // Null
        case 22: return "e.square"                          // EnumMember
        case 23: return "s.square.fill"                     // Struct
        case 24: return "bolt.fill"                         // Event
        case 25: return "plus.forwardslash.minus"           // Operator
        case 26: return "t.square"                          // TypeParameter
        default: return "questionmark.square"
        }
    }
}

/// Flattens a document-symbol tree into a depth-first list, pairing each
/// symbol with its nesting depth (0 = top-level) — used by the ⇧⌘O "Go to
/// Symbol" palette mode, which filters/displays a single flat list but still
/// wants to convey structure via indentation.
func flattenDocumentSymbols(_ symbols: [DocumentSymbol], depth: Int = 0) -> [(symbol: DocumentSymbol, depth: Int)] {
    symbols.flatMap { symbol in
        [(symbol, depth)] + flattenDocumentSymbols(symbol.children ?? [], depth: depth + 1)
    }
}

/// Walks `symbols` to find the chain of symbols (outermost → innermost)
/// whose range contains `line` — the deepest containing match wins at each
/// level. Used by `AppState.breadcrumbPath` to compute the breadcrumbs bar
/// from the cursor's current line. Returns an empty array when `line` falls
/// outside every symbol's range. Named distinctly from
/// `AppState.breadcrumbPath` (the computed property callers actually read)
/// to avoid a same-name property/function pair in the same module.
func breadcrumbSymbolPath(in symbols: [DocumentSymbol], containingLine line: Int) -> [DocumentSymbol] {
    for symbol in symbols where line >= symbol.rangeStartLine && line <= symbol.rangeEndLine {
        return [symbol] + breadcrumbSymbolPath(in: symbol.children ?? [], containingLine: line)
    }
    return []
}

// MARK: - Identifier word matching

/// ASCII identifier characters: `A–Z`, `a–z`, `0–9`, `_`, `$`. Shared by
/// `EditorView.Coordinator` (Cmd+Click clickable-target detection, ⌘D
/// "select next occurrence", rename's pre-fill) and `AppState`
/// (References-panel symbol-name lookup) so the definition of "identifier
/// character" can't drift between them.
func isIdentifierChar(_ c: unichar) -> Bool {
    (c >= 65 && c <= 90)  ||   // A–Z
    (c >= 97 && c <= 122) ||   // a–z
    (c >= 48 && c <= 57)  ||   // 0–9
    c == 95 || c == 36         // _ $
}

/// The identifier range containing or touching `location` in `ns` — e.g.
/// the caret placed immediately after a word, or at the end of the string.
/// Shared by `EditorView.Coordinator` and `AppState` for the same reason as
/// `isIdentifierChar` above.
func identifierWordRange(in ns: NSString, around location: Int) -> NSRange? {
    guard ns.length > 0 else { return nil }
    var idx = location
    if idx >= ns.length || !isIdentifierChar(ns.character(at: idx)) {
        idx -= 1
    }
    guard idx >= 0, idx < ns.length, isIdentifierChar(ns.character(at: idx)) else { return nil }

    var start = idx
    while start > 0, isIdentifierChar(ns.character(at: start - 1)) { start -= 1 }
    var end = idx + 1
    while end < ns.length, isIdentifierChar(ns.character(at: end)) { end += 1 }
    return NSRange(location: start, length: end - start)
}

// MARK: - Ghost Text Provider

enum GhostTextProvider: String, CaseIterable, Codable, Sendable {
    case none   = "none"
    case claude = "claude"
    case ollama = "ollama"

    var displayName: String {
        switch self {
        case .none:   return "Off"
        case .claude: return "Claude (Haiku)"
        case .ollama: return "Local — Ollama"
        }
    }
}

// MARK: - File Watching

/// Emitted by `FileWatchService` when a watched file or directory changes on
/// disk outside the app (git pull, another editor, a build tool).
enum FileWatchEvent: Sendable, Equatable {
    /// A watched file's contents were written to on disk.
    case fileChanged(URL)
    /// A watched file was deleted, or renamed away from the watched path.
    case fileDeleted(URL)
    /// A watched directory gained/lost/renamed an entry.
    case directoryChanged(URL)
}

// MARK: - App Settings

struct AppSettings: Codable, Sendable {
    var theme: String
    var fontSize: CGFloat
    var fontFamily: String
    var tabSize: Int
    var insertSpaces: Bool
    var wordWrap: Bool
    var claudeApiKey: String
    var showMinimap: Bool

    static var defaults: AppSettings {
        AppSettings(
            theme: "darcula",
            fontSize: 14,
            fontFamily: "JetBrains Mono",
            tabSize: 4,
            insertSpaces: true,
            wordWrap: false,
            claudeApiKey: "",
            showMinimap: true
        )
    }
}
