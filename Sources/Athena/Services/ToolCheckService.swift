// ToolCheckService.swift
// Athena — detects missing external tools (git, the claude CLI, language servers).
// Swift 6, strict concurrency.

import Foundation

// MARK: - ToolCheckService

actor ToolCheckService {

    // MARK: - Checks

    /// Git: `/usr/bin/git` is only a stub until the Command Line Tools are
    /// installed, so ask `xcode-select` whether they are.
    func gitNotice() async -> ToolNotice? {
        let installed = await run("/usr/bin/xcode-select", ["-p"])
        guard !installed else { return nil }
        return ToolNotice(
            id: "git",
            title: "Git isn't available",
            detail: "Source Control, blame and change bars need Apple's Command Line Tools.",
            installCommand: "xcode-select --install"
        )
    }

    /// The Claude Code CLI behind the Claude panel.
    func claudeNotice(binaryName: String) -> ToolNotice? {
        guard ClaudeAgentService.resolveBinary(binaryName, extraPaths: ClaudeAgentService.searchPaths) == nil
        else { return nil }
        return ToolNotice(
            id: "claude",
            title: "Claude Code isn't installed",
            detail: "The Claude panel runs the `\(binaryName)` command-line tool, which wasn't found.",
            installCommand: "curl -fsSL https://claude.ai/install.sh | bash"
        )
    }

    /// The notice for a language whose server isn't installed, or nil for a
    /// language Athena has no server for at all.
    nonisolated static func languageServerNotice(for language: Language) -> ToolNotice? {
        // Swift falls back to `xcrun sourcekit-lsp`, which always
        // resolves, so a missing server can't be told apart there.
        guard let spec = LanguageServerCatalog.spec(for: language) else { return nil }
        let label: String
        let servers: String
        switch language {
        case .typescript, .javascript:
            label = "TypeScript/JavaScript"
            servers = "`\(spec.serverName)`"
        case .css, .html, .json:
            label = "CSS/HTML/JSON"
            servers = "`vscode-css-language-server`, `vscode-html-language-server` and `vscode-json-language-server`"
        default:
            label = language.displayName
            servers = "`\(spec.serverName)`"
        }
        // Languages sharing one install share one notice id.
        return ToolNotice(
            id: "lsp.\(spec.noticeKey)",
            title: "No \(label) language server",
            detail: "Completions, errors, go to definition and quick fixes need \(servers). "
                + "You can point Athena at an existing install in Settings, Language Servers.",
            installCommand: spec.installCommand
        )
    }

    // MARK: - GitHub CLI

    /// Absolute path of the `gh` CLI, or nil when it isn't installed (the
    /// pull-request view is hidden in that case).
    nonisolated static func ghExecutable(
        searchPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    ) -> String? {
        for dir in searchPaths {
            let path = dir + "/gh"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    func ghPath() -> String? { Self.ghExecutable() }

    // MARK: - Private helper

    /// Whether `executable` exits 0. A missing executable counts as failure.
    private func run(_ executable: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }
}
