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
    // SFCC ("prophet") sessions — Prophet's launch.json keys. Any that are
    // nil fall back to dw.json, then to the active SFCC connection.
    var hostname: String? = nil
    var username: String? = nil
    var password: String? = nil
    var codeVersion: String? = nil

    /// Launch config types Athena debugs through the SFCC Script Debugger
    /// API. "prophet" is what existing VS Code launch.json files contain.
    static let sfccTypes: Set<String> = ["prophet", "sfcc"]
    var isSFCC: Bool { Self.sfccTypes.contains(type) }

    /// Parses one entry of launch.json's `configurations` array. `nil` when
    /// the three required keys (type, name, request) are missing.
    static func from(json c: [String: Any]) -> LaunchConfig? {
        guard let type = c["type"] as? String,
              let name = c["name"] as? String,
              let req  = c["request"] as? String else { return nil }
        return LaunchConfig(
            type:         type,
            request:      req,
            name:         name,
            program:      c["program"] as? String ?? "",
            args:         c["args"]    as? [String]         ?? [],
            env:          c["env"]     as? [String: String] ?? [:],
            cwd:          c["cwd"]     as? String ?? "${workspaceFolder}",
            stopOnEntry:  c["stopOnEntry"] as? Bool ?? false,
            debugPort:    c["port"] as? Int ?? c["debugPort"] as? Int,
            url:          c["url"] as? String,
            hostname:     c["hostname"] as? String,
            username:     c["username"] as? String,
            password:     c["password"] as? String,
            codeVersion:  c["codeversion"] as? String ?? c["codeVersion"] as? String ?? c["code-version"] as? String
        )
    }
}

// MARK: - Database connections

enum DBType: String, Codable, Sendable, CaseIterable {
    case postgresql = "PostgreSQL"
    case sqlite     = "SQLite"
    case mongodb    = "MongoDB"
    case mysql      = "MySQL"
    case oracle     = "Oracle"
    case mariadb    = "MariaDB"

    /// Engines Athena has a driver for. The others stay in the enum only so
    /// connections saved by older builds still decode; they're kept out of
    /// the picker and can't connect (see `AppState.connectAndBrowse`),
    /// rather than offering a choice that silently never works.
    var isSupported: Bool {
        switch self {
        case .postgresql, .sqlite: return true
        case .mongodb, .mysql, .oracle, .mariadb: return false
        }
    }

    static var supportedCases: [DBType] { allCases.filter(\.isSupported) }

    /// File-backed engines have no host/port/credentials — the `database`
    /// field is the file path.
    var isFileBased: Bool { self == .sqlite }

    var defaultPort: Int {
        switch self {
        case .postgresql: return 5432
        case .sqlite:     return 0
        case .mongodb:    return 27017
        case .mysql:      return 3306
        case .oracle:     return 1521
        case .mariadb:    return 3306
        }
    }

    var sfSymbol: String {
        switch self {
        case .postgresql: return "elephant"          // closest available
        case .sqlite:     return "doc.badge.gearshape"
        case .mongodb:    return "leaf.fill"
        case .mysql:      return "cylinder.fill"
        case .oracle:     return "building.columns.fill"
        case .mariadb:    return "cylinder.split.1x2.fill"
        }
    }

    var accentHex: UInt32 {
        switch self {
        case .postgresql: return 0x336791
        case .sqlite:     return 0x0F80CC
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
        // Always false on load, regardless of what's in the file: a live
        // `PostgresService` connection is in-memory only and can never
        // survive a relaunch, so a persisted `true` here is always stale.
        // Trusting it let "Browse Data" open an empty browser without ever
        // attempting a real connection — no error, no indication anything
        // was wrong, just a silently empty table list.
        isConnected = false
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
        // password and isConnected intentionally omitted — the former lives
        // in the Keychain, the latter is live session state that's never
        // valid to reload from disk (see init(from:) above).
    }
}

// MARK: - Database browsing

/// A schema-qualified table reference (e.g. `public.users`).
struct DBTableRef: Identifiable, Sendable, Hashable {
    var id: String { "\(schema).\(name)" }
    let schema: String
    let name: String

    /// Double-quoted, injection-safe form for interpolating into SQL —
    /// identifiers can't be bound as query parameters, so this is the
    /// standard SQL escape (embedded `"` doubled) instead.
    var qualifiedSQL: String {
        "\(DBTableRef.quoted(schema)).\(DBTableRef.quoted(name))"
    }

    static func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// One column's shape, as reported by `information_schema`.
struct DBColumn: Sendable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let dataTypeName: String
    let isPrimaryKey: Bool
}

/// A single cell's value, decoded from whatever Postgres wire type it came
/// in as. Kept to a small set of display-friendly cases rather than mirroring
/// every Postgres type — anything not specifically handled decodes as `.text`
/// via its string representation, which covers dates/UUIDs/JSON/etc. well
/// enough for a browsing/editing grid without a type for each of them.
enum DBValue: Sendable, Hashable {
    case text(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    var displayString: String {
        switch self {
        case .text(let s):   return s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .bool(let b):   return b ? "true" : "false"
        case .null:          return ""
        }
    }

    /// Parses freeform edited text back into a `DBValue`, matching
    /// `original`'s case so e.g. editing an int cell keeps producing `.int`
    /// rather than silently turning the column into text server-side. Falls
    /// back to `.text` when the typed value doesn't parse as the original
    /// type — better to let the database reject an invalid edit than to
    /// silently store something the user didn't type.
    static func parsing(_ text: String, matching original: DBValue) -> DBValue {
        if text.isEmpty { return .null }
        switch original {
        case .int:
            return Int64(text).map(DBValue.int) ?? .text(text)
        case .double:
            return Double(text).map(DBValue.double) ?? .text(text)
        case .bool:
            switch text.lowercased() {
            case "true", "t", "1", "yes": return .bool(true)
            case "false", "f", "0", "no": return .bool(false)
            default: return .text(text)
            }
        case .text, .null:
            return .text(text)
        }
    }
}

/// One fetched row. `id` is its position in the fetched result set (stable
/// for the lifetime of one fetch, which is all a `List`/`Table` selection
/// needs) — not a database identity, since not every table has one.
struct DBRow: Identifiable, Sendable {
    let id: Int
    var values: [String: DBValue]
}

/// The result of browsing one table: its columns (with primary-key flags,
/// which gate whether a cell is editable) and the rows fetched for it.
struct DBTableData: Sendable {
    let table: DBTableRef
    let columns: [DBColumn]
    var rows: [DBRow]
    /// True once every row of the table was fetched (fewer rows came back
    /// than the fetch limit) — lets the UI show "showing first N of ..." only
    /// when it's actually true.
    let isComplete: Bool
}

/// The result of one ad-hoc SQL statement from the query console. Row-
/// returning statements fill `columns`/`rows` (never editable — a result set
/// has no addressable identity); everything else reports `affectedRows`
/// when the engine can tell.
struct DBQueryResult: Sendable {
    let columns: [DBColumn]
    var rows: [DBRow]
    let affectedRows: Int?
    let elapsed: Duration
    /// True when more rows existed than the console's fetch limit.
    let isTruncated: Bool

    /// `SELECT a.id, b.id …` yields two columns named `id`. Rows are keyed
    /// by column name and the grid identifies columns by name, so the
    /// second becomes `id (2)`, third `id (3)`, and so on.
    static func uniqueColumnNames(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            return count == 1 ? name : "\(name) (\(count))"
        }
    }

    /// Whether `sql`'s leading keyword is one whose "changes" count means
    /// anything. SQLite's change counter reports the *last* DML statement,
    /// so reading it after `CREATE TABLE` would show a stale number.
    static func isDataModifying(_ sql: String) -> Bool {
        let keyword = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0.isLetter }
            .uppercased()
        return ["INSERT", "UPDATE", "DELETE", "REPLACE"].contains(keyword)
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

/// What an upload-log entry did to the sandbox: pushed a file or removed one.
enum SFCCUploadKind: String, Codable, Sendable {
    case upload, delete
    /// A whole cartridge replaced in one archive (`uploadAllCartridges`),
    /// rather than a single file saved.
    case cartridge
}

enum SFCCUploadStatus: Codable, Sendable, Equatable {
    case success
    case failure(String)
}

/// One WebDAV upload/delete attempt against the active sandbox — the rows of
/// the "Uploads" pane in the SFCC bottom panel and of the on-disk audit log
/// (`SFCCService.uploadLogFileURL`).
struct SFCCUploadRecord: Identifiable, Codable, Sendable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var relativePath: String     // cartridge-relative, e.g. "app_custom/cartridge/templates/…"
    var connectionName: String
    var codeVersion: String
    var kind: SFCCUploadKind
    var status: SFCCUploadStatus

    var fileName: String { relativePath.components(separatedBy: "/").last ?? relativePath }

    var failureMessage: String? {
        if case .failure(let message) = status { return message }
        return nil
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
    var attachments: [ClaudeAttachment] = []
}

/// A file staged for (or sent with) a Claude panel message. Athena never
/// reads or transcodes the file itself — it only passes the absolute path
/// through to the `claude` CLI process, which has its own filesystem and
/// Bash access and decodes media (e.g. video via ffmpeg) itself.
struct ClaudeAttachment: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    let url: URL

    var fileName: String { url.lastPathComponent }

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv", "mpg", "mpeg"
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff"
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"
    ]

    var isVideo: Bool { Self.videoExtensions.contains(url.pathExtension.lowercased()) }
    var isAudio: Bool { Self.audioExtensions.contains(url.pathExtension.lowercased()) }
    var isImage: Bool { Self.imageExtensions.contains(url.pathExtension.lowercased()) }

    var iconName: String {
        if isVideo { return "video" }
        if isAudio { return "waveform" }
        if isImage { return "photo" }
        return "doc"
    }
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
    /// The open workspace's root, or `nil` with no workspace open — the
    /// shell then falls back to its own default (usually `$HOME`).
    var currentDirectory: String? = nil
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

/// One `git stash list` entry, parsed by `GitService.parseStashList(_:)`.
/// `index` is the N in `stash@{N}` — git's own address for apply/pop/drop.
struct GitStash: Identifiable, Sendable, Equatable {
    var index: Int
    var message: String
    var date: Date
    var id: Int { index }
    var ref: String { "stash@{\(index)}" }
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
    /// Populated either directly off the initial `textDocument/completion`
    /// response, or later via `LSPManager.resolve(itemID:language:)` for
    /// servers that only fill it in on `completionItem/resolve`.
    var documentation: String? = nil
    /// The server's own relevance ordering (`sortText`) and, when present, a
    /// filter key distinct from `label` (`filterText`) — both `nil` for
    /// non-LSP items (Drizzle's static snippets), which fall back to
    /// alphabetical/label-based ranking.
    var sortText: String? = nil
    var filterText: String? = nil
}

// MARK: - Signature help (parameter hints)

/// One parameter of a call signature.
struct SignatureParameter: Sendable, Equatable {
    var label: String
    /// Where this parameter sits inside the signature's own label, so the
    /// active one can be emphasised without re-deriving it in the view.
    /// A server may give the label as text or as offsets; both end up here.
    var labelRange: NSRange?
    var documentation: String?
}

/// A `textDocument/signatureHelp` result: the call the caret is inside,
/// and which argument it is on.
struct SignatureHelp: Sendable, Equatable {
    var label: String
    var parameters: [SignatureParameter]
    var activeParameter: Int?
    var documentation: String?

    /// The span to emphasise, or `nil` when the caret is past the last
    /// declared parameter (a variadic call, or one argument too many).
    var activeParameterRange: NSRange? {
        guard let index = activeParameter, parameters.indices.contains(index) else { return nil }
        return parameters[index].labelRange
    }

    /// The same help with the argument index the editor counted locally, so
    /// typing a comma moves the highlight immediately instead of waiting on
    /// another round trip.
    func withActiveParameter(_ index: Int) -> SignatureHelp {
        var copy = self
        copy.activeParameter = index
        return copy
    }
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

/// Computes the sticky-scroll rows to pin above the editor viewport (plan.md
/// item 28, "G3" — VS Code's "sticky scroll"): the chain of symbols currently
/// enclosing `topVisibleLine`, reusing `breadcrumbSymbolPath`'s exact
/// containment walk rather than re-implementing scope containment — sticky
/// scroll and the breadcrumbs bar both answer "which symbols contain this
/// line," just for a different line (the topmost visible line instead of the
/// cursor's). Filtered down to only the symbols whose own opening line has
/// ALREADY scrolled above the viewport (`rangeStartLine < topVisibleLine`) —
/// a symbol whose header line IS the top visible line is already on screen,
/// so pinning a duplicate row for it would be redundant. Capped to
/// `maxLevels`, keeping the DEEPEST (innermost) entries when the chain runs
/// longer than that: the immediately-enclosing scope is what's most worth
/// surfacing while scrolling through deeply nested code; the outermost
/// containers are usually inferable from the file/Outline panel anyway.
func stickyScrollRows(in symbols: [DocumentSymbol], topVisibleLine: Int, maxLevels: Int = 4) -> [DocumentSymbol] {
    let enclosing = breadcrumbSymbolPath(in: symbols, containingLine: topVisibleLine)
        .filter { $0.rangeStartLine < topVisibleLine }
    return Array(enclosing.suffix(maxLevels))
}

/// Given the total line count and the editor's current scroll state
/// (`scrollFraction`/`visibleFraction`, both 0...1 — see
/// `EditorView.onScrollChange`), returns the 1-based line number currently at
/// the top of the viewport. This is the exact fraction→line-index arithmetic
/// `MinimapNSView.draw(_:)` already uses to position its own viewport
/// indicator (uniform per-line height, ignoring word-wrap — the same
/// approximation the minimap already ships with), pulled out as a pure,
/// testable function so sticky scroll and the minimap agree on "what's
/// visible" instead of maintaining two possibly-divergent definitions of it.
func firstVisibleLine(lineCount: Int, scrollFraction: Double, visibleFraction: Double) -> Int {
    guard lineCount > 0 else { return 1 }
    let fraction = max(0, min(1, scrollFraction))
    let visible  = max(0, min(1, visibleFraction))
    let visibleLines = visible * Double(lineCount)
    let firstVisible  = fraction * max(0, Double(lineCount) - visibleLines)
    return Int(firstVisible) + 1
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
    /// Any local (or self-hosted) server speaking the OpenAI `/v1/completions`
    /// shape — LM Studio, llama.cpp's `server`, vLLM, etc.
    case openAICompatible = "openai_compatible"

    var displayName: String {
        switch self {
        case .none:            return "Off"
        case .claude:          return "Claude (Haiku)"
        case .ollama:          return "Local — Ollama"
        case .openAICompatible: return "Local — OpenAI-compatible"
        }
    }
}

/// Lines from `text` that look like import/include statements — mirrors the
/// keyword list `EditorView.addImportLinkAttributes` uses to stamp Cmd+Click
/// import links, reused here to give local-LLM ghost text a compact list of
/// the file's imports without a full per-language parser.
func importLines(in text: String) -> [String] {
    let keywords = ["import ", "require(", " from ", "@import", "#include", "export "]
    return text.components(separatedBy: .newlines).filter { line in
        keywords.contains { line.contains($0) }
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

// MARK: - SFCC Script Debugger API (SDAPI)

/// Credentials for one SFCC sandbox debug session. See ADR 0002 for the
/// resolution order (launch config → dw.json → active connection).
struct SFCCDebugCredentials: Sendable, Equatable {
    var hostname: String
    var username: String
    var password: String
    var codeVersion: String?
}

/// `dw.json` as Prophet and the SFCC CLI write it. Only the keys the
/// debugger needs; unknown keys are ignored. Key spelling varies across
/// tools (`code-version`, `codeVersion`, `codeversion`), all accepted.
struct DWJSONConfig: Sendable, Equatable {
    var hostname: String
    var username: String?
    var password: String?
    var codeVersion: String?
    var cartridgesPath: String?

    static func parse(_ data: Data) -> DWJSONConfig? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return from(json: json)
    }

    static func from(json: [String: Any]) -> DWJSONConfig? {
        guard let host = json["hostname"] as? String, !host.isEmpty else { return nil }
        return DWJSONConfig(
            hostname: host,
            username: json["username"] as? String,
            password: json["password"] as? String,
            codeVersion: json["code-version"] as? String
                ?? json["codeVersion"] as? String
                ?? json["codeversion"] as? String,
            cartridgesPath: json["cartridgesPath"] as? String ?? json["cartridgePath"] as? String
        )
    }
}

/// Translates between local file paths and SDAPI Script Paths
/// (`/<cartridge>/cartridge/<rest>`). `cartridges` maps each cartridge name
/// to its local directory (the one containing `cartridge/`), discovered by
/// `SFCCService.discoverCartridges`. Translation to a Script Path works
/// without discovery — it only needs the `cartridge` path component; the
/// reverse direction needs the map to know where the cartridge lives.
struct SFCCCartridgeMap: Sendable, Equatable {
    var cartridges: [String: URL]

    init(cartridges: [String: URL] = [:]) {
        self.cartridges = cartridges
    }

    func scriptPath(for fileURL: URL) -> String? {
        let comps = fileURL.standardizedFileURL.pathComponents
        // The first "cartridge" component whose parent is a known cartridge
        // (or, with no map, any parent) starts the Script Path.
        for (i, comp) in comps.enumerated() where comp == "cartridge" && i > 0 && i < comps.count - 1 {
            let name = comps[i - 1]
            if cartridges.isEmpty || cartridges[name] != nil {
                let rest = comps[(i + 1)...].joined(separator: "/")
                return "/\(name)/cartridge/\(rest)"
            }
        }
        return nil
    }

    func localURL(for scriptPath: String) -> URL? {
        let trimmed = scriptPath.hasPrefix("/") ? String(scriptPath.dropFirst()) : scriptPath
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let name = String(trimmed[..<slash])
        let rest = String(trimmed[trimmed.index(after: slash)...])
        guard let dir = cartridges[name], !rest.isEmpty else { return nil }
        return dir.appendingPathComponent(rest)
    }
}

enum SFCCDebugThreadStatus: String, Sendable, Decodable {
    case halted, running, done
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SFCCDebugThreadStatus(rawValue: raw) ?? .unknown
    }
}

struct SFCCDebugLocation: Sendable, Decodable, Equatable {
    var functionName: String
    var lineNumber: Int
    var scriptPath: String

    enum CodingKeys: String, CodingKey {
        case functionName = "function_name"
        case lineNumber = "line_number"
        case scriptPath = "script_path"
    }

    init(functionName: String, lineNumber: Int, scriptPath: String) {
        self.functionName = functionName
        self.lineNumber = lineNumber
        self.scriptPath = scriptPath
    }

    /// Top-level script frames may come without a `function_name`; that
    /// must not fail the whole `threads` response.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        functionName = try c.decodeIfPresent(String.self, forKey: .functionName) ?? ""
        lineNumber = try c.decodeIfPresent(Int.self, forKey: .lineNumber) ?? 0
        scriptPath = try c.decodeIfPresent(String.self, forKey: .scriptPath) ?? ""
    }
}

struct SFCCDebugFrame: Sendable, Decodable, Equatable {
    var index: Int
    var location: SFCCDebugLocation
}

struct SFCCDebugThread: Sendable, Decodable, Equatable {
    var id: Int
    var status: SFCCDebugThreadStatus
    var callStack: [SFCCDebugFrame]

    enum CodingKeys: String, CodingKey {
        case id, status
        case callStack = "call_stack"
    }

    init(id: Int, status: SFCCDebugThreadStatus, callStack: [SFCCDebugFrame]) {
        self.id = id
        self.status = status
        self.callStack = callStack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        status = try c.decodeIfPresent(SFCCDebugThreadStatus.self, forKey: .status) ?? .unknown
        callStack = try c.decodeIfPresent([SFCCDebugFrame].self, forKey: .callStack) ?? []
    }
}

/// One entry of an SDAPI `object_members` list: a variable in a frame, or a
/// member of an object when fetched with an `object_path`.
struct SFCCDebugMember: Sendable, Decodable, Equatable {
    var name: String
    var type: String?
    var value: String?
    var scope: String?
    var parent: String?
}

struct SFCCDebugBreakpoint: Sendable, Decodable, Equatable {
    var id: Int
    var lineNumber: Int
    var scriptPath: String

    enum CodingKeys: String, CodingKey {
        case id
        case lineNumber = "line_number"
        case scriptPath = "script_path"
    }
}
