// ClaudeCLIService.swift — runs the local `claude` / `claude-work` CLI and streams output.

import Foundation

actor ClaudeCLIService {

    private var currentProcess: Process?

    // MARK: Public API

    /// Spawns `command` via a login shell, pipes `prompt` through stdin, and
    /// streams stdout chunks back through an AsyncStream.
    func stream(prompt: String, command: String) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let process    = Process()
            let outPipe    = Pipe()
            let errPipe    = Pipe()

            // Pass prompt via env var — avoids every shell-escaping edge case.
            var env = ProcessInfo.processInfo.environment
            env["ATHENA_PROMPT"] = prompt

            // Login shell (-l) so $PATH includes brew/nix/volta installations.
            // `--print` (-p) runs the CLI non-interactively: it reads the piped
            // prompt and streams the response to stdout. Without it, `claude`
            // launches its interactive TUI and emits no usable output here.
            process.executableURL  = URL(fileURLWithPath: "/bin/zsh")
            process.arguments      = ["-lc", "printf '%s' \"$ATHENA_PROMPT\" | \(command) --print"]
            process.standardOutput = outPipe
            process.standardError  = errPipe
            process.environment    = env

            // Track output + drain stderr so the pipe buffer can't fill and
            // block the process, and so we can surface errors if stdout is empty.
            let state = CLIStreamState()

            // Stream stdout as it arrives.
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                state.markProducedOutput()
                continuation.yield(text)
            }

            // Drain stderr; only surfaced as a fallback if stdout was empty.
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                state.appendError(text)
            }

            process.terminationHandler = { _ in
                // If the CLI produced nothing on stdout, surface the error so the
                // user isn't left with a silent, empty response bubble.
                if !state.producedOutput {
                    let err = state.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = err.isEmpty
                        ? "⚠️ '\(command)' produced no output. Make sure it is installed and signed in (try `\(command) --print \"hi\"` in a terminal)."
                        : "⚠️ \(err)"
                    continuation.yield(message)
                }
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.yield("⚠️ Could not launch '\(command)'. Make sure it is installed and on PATH.")
                continuation.finish()
                return
            }

            Task { self.storeProcess(process) }
        }
    }

    /// Terminates any in-flight CLI process.
    func abort() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    // MARK: Private

    private func storeProcess(_ p: Process) {
        currentProcess = p
    }
}

// MARK: - CLIStreamState

/// Thread-safe scratch state shared by the stdout/stderr readability handlers
/// and the termination handler, which all fire on arbitrary background threads.
private final class CLIStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var _producedOutput = false
    private var _errorText = ""

    var producedOutput: Bool {
        lock.lock(); defer { lock.unlock() }
        return _producedOutput
    }

    var errorText: String {
        lock.lock(); defer { lock.unlock() }
        return _errorText
    }

    func markProducedOutput() {
        lock.lock(); defer { lock.unlock() }
        _producedOutput = true
    }

    func appendError(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _errorText += text
    }
}
