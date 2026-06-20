// GitBlameService.swift
// Athena — runs git blame and caches per-file blame data.
// Swift 6, strict concurrency.

import Foundation

actor GitBlameService {

    private var cache: [String: [Int: BlameLine]] = [:]

    // MARK: - Public API

    func blame(fileURL: URL, workspaceURL: URL) async -> [Int: BlameLine] {
        let key = fileURL.path
        if let hit = cache[key] { return hit }

        let result = (try? await runBlame(fileURL: fileURL, workspaceURL: workspaceURL)) ?? [:]
        cache[key] = result
        return result
    }

    func invalidate(fileURL: URL) {
        cache.removeValue(forKey: fileURL.path)
    }

    // MARK: - Private

    private func runBlame(fileURL: URL, workspaceURL: URL) async throws -> [Int: BlameLine] {
        let output = try await git(args: ["blame", "--porcelain", fileURL.path], at: workspaceURL)
        return parse(output: output)
    }

    private func parse(output: String) -> [Int: BlameLine] {
        var result: [Int: BlameLine] = [:]
        // Commit info accumulator so repeated lines of the same commit reuse metadata.
        var known: [String: (author: String, date: Date, summary: String)] = [:]

        let lines = output.components(separatedBy: "\n")
        let nullHash = String(repeating: "0", count: 40)
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Each blame block starts with: <40-char-hash> <orig-line> <final-line> [<count>]
            guard line.count > 40,
                  line[line.index(line.startIndex, offsetBy: 40)] == " "
            else { i += 1; continue }

            let hash = String(line.prefix(40))
            guard hash.allSatisfy({ $0.isHexDigit }) else { i += 1; continue }

            let headerTail = line.dropFirst(41).split(separator: " ", maxSplits: 3)
            guard headerTail.count >= 2, let finalLine = Int(headerTail[1]) else { i += 1; continue }

            i += 1

            var author  = known[hash]?.author  ?? ""
            var date    = known[hash]?.date    ?? Date()
            var summary = known[hash]?.summary ?? ""

            if known[hash] == nil {
                // Full commit metadata follows (only on first occurrence of this hash).
                while i < lines.count && !lines[i].hasPrefix("\t") {
                    let info = lines[i]
                    if info.hasPrefix("author ") && !info.hasPrefix("author-") {
                        author = String(info.dropFirst(7))
                    } else if info.hasPrefix("author-time ") {
                        let ts = Double(info.dropFirst(12)) ?? 0
                        date = Date(timeIntervalSince1970: ts)
                    } else if info.hasPrefix("summary ") {
                        summary = String(info.dropFirst(8))
                    }
                    i += 1
                }
                known[hash] = (author, date, summary)
            } else {
                // Skip to the tab-prefixed content line.
                while i < lines.count && !lines[i].hasPrefix("\t") { i += 1 }
            }

            // Consume the content line (starts with '\t').
            if i < lines.count && lines[i].hasPrefix("\t") { i += 1 }

            if hash == nullHash { continue }  // uncommitted line

            result[finalLine] = BlameLine(hash: hash, author: author, date: date, summary: summary)
        }

        return result
    }

    private func git(args: [String], at url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments     = args
            process.currentDirectoryURL = url

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError  = err

            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume(returning:
                        String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                } else {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: GitError.commandFailed(msg))
                }
            }

            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}
