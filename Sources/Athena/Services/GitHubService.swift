// GitHubService.swift
// Athena — pull request + CI status through the `gh` CLI, when installed.
// Swift 6, strict concurrency.

import Foundation

// MARK: - GitHubError

enum GitHubError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "gh command failed" : trimmed
        }
    }
}

// MARK: - GitHubService

actor GitHubService {

    // MARK: - Status

    /// The open PR for the checked-out branch, nil when there is none.
    func pullRequest(gh: String, at url: URL) async throws -> GitPullRequestInfo? {
        let fields = "number,title,state,url,headRefName,isDraft,reviewDecision"
        let json = try await run(gh, ["pr", "status", "--json", fields], at: url)
        return GitHubParsing.parsePullRequestStatus(json)
    }

    /// CI checks of the current branch's PR. `gh pr checks` exits 8 while
    /// checks are pending and 1 when one failed; both still print the JSON.
    func checks(gh: String, at url: URL) async throws -> [GitCICheck] {
        let json = try await run(gh, ["pr", "checks", "--json", "name,workflow,bucket,link"], at: url, allowedExitCodes: [0, 1, 8])
        return GitHubParsing.parseChecks(json)
    }

    // MARK: - Private helper

    private func run(_ executable: String, _ args: [String], at url: URL, allowedExitCodes: Set<Int32> = [0]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = url
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()

        async let stdoutData = Self.drain(out.fileHandleForReading)
        async let stderrData = Self.drain(err.fileHandleForReading)
        let stdout = String(decoding: await stdoutData, as: UTF8.self)
        let stderr = String(decoding: await stderrData, as: UTF8.self)
        var status: Int32 = 0
        for await code in termination { status = code }

        guard allowedExitCodes.contains(status) else {
            throw GitHubError.failed(stderr.isEmpty ? stdout : stderr)
        }
        return stdout
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
