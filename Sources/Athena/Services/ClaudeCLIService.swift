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

            // Pass prompt via env var — avoids every shell-escaping edge case.
            var env = ProcessInfo.processInfo.environment
            env["ATHENA_PROMPT"] = prompt

            // Login shell (-l) so $PATH includes brew/nix/volta installations.
            process.executableURL  = URL(fileURLWithPath: "/bin/zsh")
            process.arguments      = ["-lc", "printf '%s' \"$ATHENA_PROMPT\" | \(command)"]
            process.standardOutput = outPipe
            process.standardError  = Pipe()   // silence CLI status lines
            process.environment    = env

            // Stream stdout as it arrives.
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                continuation.yield(text)
            }

            process.terminationHandler = { _ in
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
