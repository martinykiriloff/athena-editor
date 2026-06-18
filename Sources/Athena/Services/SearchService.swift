// SearchService.swift
// Athena — ripgrep-backed workspace search.
// Swift 6, strict concurrency.

import Foundation

// MARK: - SearchService

actor SearchService {

    // MARK: State

    private var currentTask: Task<Void, Never>?

    // MARK: Public API

    /// Runs ripgrep in `url` for `query` and yields results as they are parsed.
    /// The stream finishes when all output has been read, the task is cancelled,
    /// or `cancel()` is called. Falls back to finishing immediately when `rg`
    /// cannot be found on the system.
    func search(
        query: String,
        in url: URL,
        regex: Bool,
        caseSensitive: Bool
    ) -> AsyncStream<SearchResult> {
        AsyncStream { continuation in
            let task = Task {
                guard let rg = rgExecutable() else {
                    continuation.finish()
                    return
                }

                var args: [String] = ["--line-number", "--no-heading", "--color=never"]
                if !caseSensitive { args.append("--ignore-case") }
                if !regex        { args.append("--fixed-strings") }
                args += [query, url.path]

                let process = Process()
                process.executableURL = URL(fileURLWithPath: rg)
                process.arguments = args

                let pipe = Pipe()
                process.standardOutput = pipe
                let handle = pipe.fileHandleForReading

                do {
                    try process.run()
                } catch {
                    continuation.finish()
                    return
                }

                let data = handle.readDataToEndOfFile()
                process.waitUntilExit()

                let output = String(data: data, encoding: .utf8) ?? ""

                for line in output.components(separatedBy: "\n") {
                    if Task.isCancelled { break }
                    guard !line.isEmpty else { continue }

                    // rg output format: <path>:<lineNumber>:<content>
                    // Paths themselves may contain ':', so split on the first two colons only.
                    let parts = line.components(separatedBy: ":")
                    guard parts.count >= 3 else { continue }

                    let filePath   = parts[0]
                    let lineNumber = Int(parts[1]) ?? 0
                    let lineContent = parts[2...].joined(separator: ":")

                    let result = SearchResult(
                        filePath: filePath,
                        lineNumber: lineNumber,
                        lineContent: lineContent,
                        matchRange: NSRange(location: 0, length: 0)
                    )
                    continuation.yield(result)
                }

                continuation.finish()
            }

            let t = task
            continuation.onTermination = { _ in t.cancel() }

            Task { self.storeCurrentTask(task) }
        }
    }

    /// Cancels the in-flight search, if any.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: Private helpers

    private func rgExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func storeCurrentTask(_ task: Task<Void, Never>) {
        currentTask = task
    }
}
