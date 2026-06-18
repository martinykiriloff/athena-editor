// SharedTypes.swift
// Athena — shared domain types used across the entire application.
// Swift 6, strict concurrency.

import Foundation
import SwiftUI

// MARK: - Panels

enum SidebarPanel: String, Sendable, CaseIterable {
    case files, git, search, database
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
    var password: String    = ""   // TODO: move to Keychain
    var isConnected: Bool   = false

    init(name: String, type: DBType) {
        self.name = name
        self.type = type
        self.port = type.defaultPort
    }
}

enum BottomPanel: String, Sendable, CaseIterable {
    case terminal, problems, output, chat
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

    static func untitled() -> TabModel {
        TabModel(title: "Untitled")
    }
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

// MARK: - Search

struct SearchResult: Identifiable, Sendable {
    let id = UUID()
    var filePath: String
    var lineNumber: Int
    var lineContent: String
    var matchRange: NSRange
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
