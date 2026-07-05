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

    /// Discards unstaged working-tree changes for `paths`, restoring them to
    /// their last-committed (HEAD/index) contents. Destructive and irreversible.
    func restore(_ paths: [String], at url: URL) async throws {
        _ = try await run(args: ["checkout", "--"] + paths, at: url)
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

    /// Unified diff for a single commit (`git show <hash>`), reused by
    /// `AppState.openDiffViewer(forCommit:)` to feed the same
    /// `UnifiedDiffParser`/`DiffViewerView` rendering path as the working-tree
    /// diff above (plan.md item 20 point 2 — no second diff renderer). `git
    /// show`'s leading commit-message header (before the first `@@` hunk
    /// line) is left in the returned text: `UnifiedDiffParser.parse` already
    /// ignores every line until it sees a hunk header, so it's harmless.
    func diff(commit: String, at url: URL) async throws -> String {
        try await run(args: ["show", commit], at: url)
    }

    // MARK: - Branches

    func branches(at url: URL) async throws -> [GitBranch] {
        let output = try await run(args: ["branch", "-a"], at: url)
        return Self.parseBranches(output)
    }

    /// Pure parser for `git branch -a`'s raw text output, separated out from
    /// `branches(at:)` so it's directly unit-testable without a live git
    /// process (see `GitBranchParsingTests`). A `static` member of an actor
    /// type isn't actor-isolated, so this can be called from anywhere,
    /// synchronously.
    ///
    /// Sample input this parses:
    /// ```
    /// * main
    ///   develop
    ///   remotes/origin/HEAD -> origin/main
    ///   remotes/origin/main
    ///   remotes/origin/develop
    /// ```
    /// Handles:
    /// - the `"* "` current-branch marker,
    /// - `remotes/<remote>/<branch>` entries, surfaced with `isRemote = true`
    ///   and `name` kept as `"<remote>/<branch>"` (e.g. `"origin/main"`) —
    ///   that's what `git checkout <name>` expects in order to create a local
    ///   tracking branch from it,
    /// - a detached-HEAD marker line (`"* (HEAD detached at ...)"`), dropped
    ///   entirely — not a real, checkable-out branch,
    /// - the remote's symbolic HEAD pointer
    ///   (`"remotes/origin/HEAD -> origin/main"`), also dropped — an alias,
    ///   not itself a real branch.
    static func parseBranches(_ output: String) -> [GitBranch] {
        var result: [GitBranch] = []

        for rawLine in output.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            var isCurrent = false
            if line.hasPrefix("* ") {
                isCurrent = true
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }

            // Detached HEAD, e.g. "(HEAD detached at abc1234)" — not a branch.
            if line.hasPrefix("(") { continue }

            var isRemote = false
            if line.hasPrefix("remotes/") {
                isRemote = true
                line = String(line.dropFirst("remotes/".count))
            }

            // The remote's symbolic HEAD pointer, e.g.
            // "origin/HEAD -> origin/main" — an alias, not a real branch.
            if line.contains(" -> ") { continue }

            guard !line.isEmpty else { continue }
            result.append(GitBranch(name: line, isCurrent: isCurrent, isRemote: isRemote))
        }

        return result
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

    // MARK: - Clone

    /// Clones `url` into `destination` by running `git clone <url> <folder>`
    /// with the working directory set to `destination`'s *parent* —
    /// `destination` itself must not already exist (git creates it), unlike
    /// every other method in this actor, which runs `at:` an existing repo
    /// directory. See `AppState.cloneRepository(urlString:destinationParent:)`
    /// for the Welcome screen's "Clone Repository" flow (plan.md item 20,
    /// "D6") that computes `destination` before calling this.
    func clone(url: String, into destination: URL) async throws {
        let parent = destination.deletingLastPathComponent()
        let folderName = destination.lastPathComponent
        _ = try await run(args: ["clone", url, folderName], at: parent)
    }

    /// Derives the folder name `git clone <url>` itself would choose when
    /// given no explicit target directory — e.g.
    /// `"https://github.com/user/repo.git"` → `"repo"` — so a caller can turn
    /// a user-picked parent folder into a full destination path before
    /// calling `clone(url:into:)`. Pure/static so it's unit-testable without
    /// a live git process (see `RepoFolderNameTests`).
    static func repoFolderName(from urlString: String) -> String {
        var name = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix("/") { name.removeLast() }

        if let lastSlash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: lastSlash)...])
        } else if let lastColon = name.lastIndex(of: ":") {
            // scp-style SSH URLs with no slash, e.g. "git@host:repo.git".
            name = String(name[name.index(after: lastColon)...])
        }

        if name.hasSuffix(".git") {
            name = String(name.dropLast(".git".count))
        }

        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "repository" : name
    }
}
