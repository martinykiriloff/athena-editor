import Foundation

enum GitError: Error {
    case commandFailed(String)
    case notARepo
    case parseError
}

actor GitService {

    // MARK: - Private helper

    private func run(args: [String], at url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = url

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } else {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: data, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: GitError.commandFailed(errMsg))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Status

    func status(at url: URL) async throws -> GitStatus {
        let porcelain = try await run(args: ["status", "--porcelain=v1"], at: url)

        let branch: String
        do {
            branch = try await run(args: ["branch", "--show-current"], at: url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            branch = ""
        }

        var staged: [GitFileChange] = []
        var unstaged: [GitFileChange] = []
        var untracked: [GitFileChange] = []

        for line in porcelain.components(separatedBy: "\n") {
            guard line.count >= 2 else { continue }

            let indexStatus = line[line.index(line.startIndex, offsetBy: 0)]
            let workTreeStatus = line[line.index(line.startIndex, offsetBy: 1)]
            let path = String(line.dropFirst(3))

            if path.isEmpty { continue }

            if indexStatus == "?" && workTreeStatus == "?" {
                untracked.append(GitFileChange(path: path, status: "??"))
                continue
            }

            if indexStatus != " " && indexStatus != "?" {
                staged.append(GitFileChange(path: path, status: String(indexStatus)))
            }
            if workTreeStatus != " " && workTreeStatus != "?" {
                unstaged.append(GitFileChange(path: path, status: String(workTreeStatus)))
            }
        }

        var ahead = 0
        var behind = 0
        if let revList = try? await run(
            args: ["rev-list", "--count", "--left-right", "@{upstream}...HEAD"],
            at: url
        ) {
            let parts = revList.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
            if parts.count == 2 {
                behind = Int(parts[0]) ?? 0
                ahead = Int(parts[1]) ?? 0
            }
        }

        return GitStatus(
            branch: branch,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked,
            ahead: ahead,
            behind: behind
        )
    }

    // MARK: - Staging

    func stage(_ paths: [String], at url: URL) async throws {
        _ = try await run(args: ["add", "--"] + paths, at: url)
    }

    func unstage(_ paths: [String], at url: URL) async throws {
        _ = try await run(args: ["reset", "HEAD", "--"] + paths, at: url)
    }

    func stageAll(at url: URL) async throws {
        _ = try await run(args: ["add", "-A"], at: url)
    }

    // MARK: - Commit / Push / Pull

    func commit(message: String, at url: URL) async throws {
        _ = try await run(args: ["commit", "-m", message], at: url)
    }

    func push(at url: URL) async throws {
        _ = try await run(args: ["push"], at: url)
    }

    func pull(at url: URL) async throws {
        _ = try await run(args: ["pull"], at: url)
    }

    // MARK: - Log

    func log(at url: URL, limit: Int) async throws -> [GitCommit] {
        let format = "--format=%H|%h|%s|%an|%at"
        let output = try await run(args: ["log", format, "-" + String(limit)], at: url)

        var commits: [GitCommit] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 5 else { continue }

            let hash = parts[0]
            let shortHash = parts[1]
            let message = parts[2]
            let author = parts[3]
            let atStr = parts[4]
            let date = Date(timeIntervalSince1970: Double(atStr) ?? 0)

            commits.append(GitCommit(
                hash: hash,
                shortHash: shortHash,
                message: message,
                author: author,
                date: date
            ))
        }
        return commits
    }

    // MARK: - Diff

    func diff(path: String, staged: Bool, at url: URL) async throws -> String {
        if staged {
            return try await run(args: ["diff", "--cached", "--", path], at: url)
        } else {
            return try await run(args: ["diff", "--", path], at: url)
        }
    }

    // MARK: - Branches

    func branches(at url: URL) async throws -> [String] {
        let output = try await run(args: ["branch", "-a"], at: url)
        return output
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                var name = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if name.hasPrefix("* ") {
                    name = String(name.dropFirst(2))
                }
                if name.hasPrefix("remotes/") {
                    name = String(name.dropFirst("remotes/".count))
                }
                name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
    }

    func createBranch(_ name: String, at url: URL) async throws {
        _ = try await run(args: ["checkout", "-b", name], at: url)
    }

    func checkout(_ branch: String, at url: URL) async throws {
        _ = try await run(args: ["checkout", branch], at: url)
    }

    // MARK: - Current Branch

    func currentBranch(at url: URL) async throws -> String {
        let result = try await run(args: ["branch", "--show-current"], at: url)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
