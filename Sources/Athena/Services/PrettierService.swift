// PrettierService.swift
// Athena — formats file content via the workspace's own Prettier install.
// Swift 6, strict concurrency.

import Foundation

enum PrettierError: Error {
    case commandFailed(String)
}

// MARK: - PrettierService

actor PrettierService {

    /// Formats `content` by piping it through `workspaceRoot`'s own
    /// `node_modules/.bin/prettier` — never a global install, so the
    /// project's own Prettier version and `.prettierrc`/config are honored,
    /// matching how `NPMScriptService` detects the project's own package
    /// manager instead of assuming one. Returns `nil` (never throws for this
    /// case) when no project-local Prettier binary is found, so callers can
    /// silently skip formatting rather than fail the save.
    func format(fileURL: URL, content: String, workspaceRoot: URL) async throws -> String? {
        let binary = workspaceRoot
            .appendingPathComponent("node_modules")
            .appendingPathComponent(".bin")
            .appendingPathComponent("prettier")

        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }

        return try await run(binary: binary, fileURL: fileURL, content: content)
    }

    // MARK: - Private helper

    /// Runs `prettier --stdin-filepath <path>`, feeding `content` on stdin
    /// and returning the formatted stdout. Mirrors `GitService.run(args:at:)`'s
    /// `Process`/`Pipe`/`withCheckedThrowingContinuation` shape, but drains
    /// stdout/stderr concurrently via readability handlers (rather than only
    /// at termination) so writing a file larger than the stdin pipe's OS
    /// buffer can't deadlock against Prettier's own stdout buffer filling up.
    private func run(binary: URL, fileURL: URL, content: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--stdin-filepath", fileURL.path]

            let stdinPipe  = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput  = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            let state = PrettierOutputState()

            stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                state.appendStdout(data)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                state.appendStderr(data)
            }

            process.terminationHandler = { p in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 {
                    continuation.resume(returning: String(data: state.stdout, encoding: .utf8) ?? "")
                } else {
                    let errMsg = String(data: state.stderr, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: PrettierError.commandFailed(errMsg))
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }

            // Write off the calling thread so a large file can't block on the
            // stdin pipe's OS buffer while stdout is being drained above.
            DispatchQueue.global(qos: .utility).async {
                if let data = content.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                try? stdinPipe.fileHandleForWriting.close()
            }
        }
    }
}

// MARK: - PrettierOutputState

/// Thread-safe accumulator for stdout/stderr bytes, appended to from the
/// readability handlers (arbitrary background threads) and read from the
/// termination handler.
private final class PrettierOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout = Data()
    private var _stderr = Data()

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return _stdout }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return _stderr }

    func appendStdout(_ data: Data) { lock.lock(); _stdout.append(data); lock.unlock() }
    func appendStderr(_ data: Data) { lock.lock(); _stderr.append(data); lock.unlock() }
}
