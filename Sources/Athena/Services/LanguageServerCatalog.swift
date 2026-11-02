// LanguageServerCatalog.swift
// Athena — which language server each Language launches, plus pure launch-command resolution.
// Swift 6, strict concurrency.

import Foundation

// MARK: - LanguageServerSpec

/// How to find, launch and install one language's server.
struct LanguageServerSpec: Sendable, Equatable {
    /// Executable name looked up on the login-shell `$PATH`.
    var executable: String
    var arguments: [String]
    /// Fixed install locations tried when `$PATH` lookup fails.
    var fallbackPaths: [String]
    /// Shown in the missing-server notice ("Completions … need `name`").
    var serverName: String
    var installCommand: String
    /// Languages sharing one install (CSS/HTML/JSON, TS/JS) share one notice.
    var noticeKey: String
}

/// A resolved server launch.
struct LanguageServerLaunch: Sendable, Equatable {
    var executable: String
    var arguments: [String]
}

// MARK: - Lookups

/// The filesystem and `$PATH` queries resolution depends on, injectable so
/// tests don't touch the machine's real installs.
struct LanguageServerLookups: Sendable {
    /// First executable named `name` on the user's resolved `$PATH`.
    var executableNamed: @Sendable (String) async -> String?
    /// Whether `path` is an executable file.
    var isExecutable: @Sendable (String) -> Bool
}

// MARK: - LanguageServerCatalog

enum LanguageServerCatalog {

    // MARK: Table

    private static let homebrew = ["/opt/homebrew/bin", "/usr/local/bin"]

    private static func brewPaths(_ name: String) -> [String] {
        homebrew.map { ($0 as NSString).appendingPathComponent(name) }
    }

    private static let langservers = "npm install -g vscode-langservers-extracted"

    /// The server spec for `language`, or nil when Athena has none. Swift is
    /// handled separately (`sourcekit-lsp` ships with the toolchain).
    static func spec(for language: Language) -> LanguageServerSpec? {
        switch language {
        case .typescript, .javascript:
            return LanguageServerSpec(
                executable: "typescript-language-server", arguments: ["--stdio"],
                fallbackPaths: brewPaths("typescript-language-server"),
                serverName: "typescript-language-server",
                installCommand: "npm install -g typescript-language-server typescript",
                noticeKey: "typescript")
        case .python:
            return LanguageServerSpec(
                executable: "pylsp", arguments: [], fallbackPaths: brewPaths("pylsp"),
                serverName: "pylsp", installCommand: "pip3 install 'python-lsp-server[all]'",
                noticeKey: "python")
        case .rust:
            return LanguageServerSpec(
                executable: "rust-analyzer", arguments: [],
                fallbackPaths: brewPaths("rust-analyzer")
                    + [(NSHomeDirectory() as NSString).appendingPathComponent(".cargo/bin/rust-analyzer")],
                serverName: "rust-analyzer", installCommand: "rustup component add rust-analyzer",
                noticeKey: "rust")
        case .go:
            return LanguageServerSpec(
                executable: "gopls", arguments: [], fallbackPaths: brewPaths("gopls"),
                serverName: "gopls", installCommand: "go install golang.org/x/tools/gopls@latest",
                noticeKey: "go")
        case .css:
            return LanguageServerSpec(
                executable: "vscode-css-language-server", arguments: ["--stdio"],
                fallbackPaths: brewPaths("vscode-css-language-server"),
                serverName: "vscode-css-language-server", installCommand: langservers,
                noticeKey: "vscode-langservers")
        case .html:
            return LanguageServerSpec(
                executable: "vscode-html-language-server", arguments: ["--stdio"],
                fallbackPaths: brewPaths("vscode-html-language-server"),
                serverName: "vscode-html-language-server", installCommand: langservers,
                noticeKey: "vscode-langservers")
        case .json:
            return LanguageServerSpec(
                executable: "vscode-json-language-server", arguments: ["--stdio"],
                fallbackPaths: brewPaths("vscode-json-language-server"),
                serverName: "vscode-json-language-server", installCommand: langservers,
                noticeKey: "vscode-langservers")
        case .yaml:
            return LanguageServerSpec(
                executable: "yaml-language-server", arguments: ["--stdio"],
                fallbackPaths: brewPaths("yaml-language-server"),
                serverName: "yaml-language-server",
                installCommand: "npm install -g yaml-language-server",
                noticeKey: "yaml")
        case .vue:
            return LanguageServerSpec(
                executable: "vue-language-server", arguments: ["--stdio"],
                fallbackPaths: brewPaths("vue-language-server"),
                serverName: "vue-language-server",
                installCommand: "npm install -g @vue/language-server typescript",
                noticeKey: "vue")
        case .svelte:
            return LanguageServerSpec(
                executable: "svelteserver", arguments: ["--stdio"],
                fallbackPaths: brewPaths("svelteserver"),
                serverName: "svelteserver",
                installCommand: "npm install -g svelte-language-server typescript",
                noticeKey: "svelte")
        default:
            return nil
        }
    }

    /// Languages whose server command can be overridden in Settings.
    static let configurableLanguages: [Language] =
        [.swift] + Language.allCases.filter { $0 != .swift && spec(for: $0) != nil }

    // MARK: Resolution

    /// Resolves the launch command for `language`.
    ///
    /// With an override path set, only that is tried: a bare name is looked up
    /// on `$PATH`, anything containing `/` (after `~` expansion) must be an
    /// executable file. A wrong override yields nil rather than silently
    /// launching a different server. Override arguments, when non-empty,
    /// replace the defaults. Without an override: `$PATH` first, then the
    /// fixed install locations. Swift falls back to `xcrun sourcekit-lsp`.
    static func resolve(
        language: Language,
        override: LanguageServerOverride?,
        lookups: LanguageServerLookups
    ) async -> LanguageServerLaunch? {
        let override = (override?.isEmpty ?? true) ? nil : override
        let overrideArgs = override.map { splitArguments($0.arguments) } ?? []
        let overridePath = override?.path.trimmingCharacters(in: .whitespaces) ?? ""

        if language == .swift {
            let args = overrideArgs
            if !overridePath.isEmpty {
                return await resolveOverridePath(overridePath, lookups: lookups)
                    .map { LanguageServerLaunch(executable: $0, arguments: args) }
            }
            if lookups.isExecutable("/usr/bin/sourcekit-lsp") {
                return LanguageServerLaunch(executable: "/usr/bin/sourcekit-lsp", arguments: args)
            }
            if lookups.isExecutable("/usr/bin/xcrun") {
                return LanguageServerLaunch(executable: "/usr/bin/xcrun", arguments: ["sourcekit-lsp"] + args)
            }
            return nil
        }

        guard let spec = spec(for: language) else { return nil }
        let args = overrideArgs.isEmpty ? spec.arguments : overrideArgs

        if !overridePath.isEmpty {
            return await resolveOverridePath(overridePath, lookups: lookups)
                .map { LanguageServerLaunch(executable: $0, arguments: args) }
        }
        if let found = await lookups.executableNamed(spec.executable) {
            return LanguageServerLaunch(executable: found, arguments: args)
        }
        if let fixed = spec.fallbackPaths.first(where: lookups.isExecutable) {
            return LanguageServerLaunch(executable: fixed, arguments: args)
        }
        return nil
    }

    private static func resolveOverridePath(_ raw: String, lookups: LanguageServerLookups) async -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return lookups.isExecutable(expanded) ? expanded : nil
        }
        return await lookups.executableNamed(expanded)
    }

    /// Splits on whitespace, honouring single and double quotes so a path
    /// with spaces can be passed as one argument.
    static func splitArguments(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in raw {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken { out.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { out.append(current) }
        return out
    }
}
