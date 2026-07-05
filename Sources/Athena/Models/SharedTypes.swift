// SharedTypes.swift
// Athena — shared domain types used across the entire application.
// Swift 6, strict concurrency.

import Foundation
import SwiftUI

// MARK: - Panels

enum SidebarPanel: String, Sendable, CaseIterable {
    case files, git, search, database, sfcc, npm, debug
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
    case terminal, scripts, output, problems, chat, sfcclogs
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

enum DiagnosticSeverity: Sendable {
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

    static func untitled() -> TabModel {
        TabModel(title: "Untitled")
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
    var ahead: Int = 0
    var behind: Int = 0

    var isClean: Bool {
        staged.isEmpty && unstaged.isEmpty && untracked.isEmpty
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

struct Diagnostic: Identifiable, Sendable {
    let id = UUID()
    var fileURL: URL
    var line: Int
    var column: Int
    var message: String
    var severity: DiagnosticSeverity
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
