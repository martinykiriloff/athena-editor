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
        let server: (language: String, name: String, command: String)
        switch language {
        case .typescript, .javascript:
            server = ("TypeScript/JavaScript", "typescript-language-server",
                      "npm install -g typescript-language-server typescript")
        case .python:
            server = ("Python", "pylsp", "pip3 install 'python-lsp-server[all]'")
        case .rust:
            server = ("Rust", "rust-analyzer", "rustup component add rust-analyzer")
        case .go:
            server = ("Go", "gopls", "go install golang.org/x/tools/gopls@latest")
        default:
            // Swift falls back to `xcrun sourcekit-lsp`, which always
            // resolves, so a missing server can't be told apart there.
            return nil
        }
        // JavaScript and TypeScript share one server, so one notice.
        let key = language == .javascript ? Language.typescript.rawValue : language.rawValue
        return ToolNotice(
            id: "lsp.\(key)",
            title: "No \(server.language) language server",
            detail: "Completions, errors, go to definition and quick fixes need `\(server.name)`.",
            installCommand: server.command
        )
    }

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
