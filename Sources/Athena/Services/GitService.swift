import Foundation

enum GitError: LocalizedError {
    case commandFailed(String)
    case notARepo
    case parseError

    /// Without this, `error.localizedDescription` on a failed git command
    /// reads "The operation couldn't be completed" and git's actual stderr
    /// (the only useful part) never reaches the user.
    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "git command failed" : trimmed
        case .notARepo:   return "Not a git repository"
        case .parseError: return "Couldn't parse git output"
        }
    }
}

actor GitService {

    // MARK: - Private helper

    /// Both pipes are drained concurrently while git runs: draining only in
    /// the termination handler deadlocks once output exceeds the 64 KB pipe
    /// buffer (`git show` of a large commit). On failure the message is
    /// stderr, or stdout when stderr is empty — a conflicting merge/pull
    /// reports "CONFLICT …" on stdout with nothing on stderr.
    private func run(args: [String], at url: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        // No terminal is attached: a push/pull that needs credentials
        // must fail with git's message, not hang forever on a prompt.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // Installed before `run()` — a handler set after a fast exit never fires.
        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()

        async let stdoutData = Self.drain(stdoutHandle)
        async let stderrData = Self.drain(stderrHandle)
        let stdout = String(decoding: await stdoutData, as: UTF8.self)
        let stderr = String(decoding: await stderrData, as: UTF8.self)
        var status: Int32 = 0
        for await code in termination { status = code }

        guard status == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
            throw GitError.commandFailed(message)
        }
        return stdout
    }

    /// Blocking `readDataToEndOfFile` on a GCD queue, not the cooperative
    /// pool, bridged back with a continuation. (`FileHandle.bytes` stalled
    /// on a full pipe in practice.)
    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
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

        let (staged, unstaged, untracked, conflicted) = Self.parsePorcelainStatus(porcelain)

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
            conflicted: conflicted,
            ahead: ahead,
            behind: behind
        )
    }

    /// Classifies every `git status --porcelain=v1` line into this app's
    /// four buckets. Pulled out as a pure `static func` (mirrors
    /// `parseBranches`/`repoFolderName`) so the porcelain-format decisions —
    /// including which XY combinations mean "unmerged" — are unit-testable
    /// without shelling out to git (see `GitServiceParsePorcelainStatusTests`).
    static func parsePorcelainStatus(_ porcelain: String) -> (
        staged: [GitFileChange], unstaged: [GitFileChange],
        untracked: [GitFileChange], conflicted: [GitFileChange]
    ) {
        var staged: [GitFileChange] = []
        var unstaged: [GitFileChange] = []
        var untracked: [GitFileChange] = []
        var conflicted: [GitFileChange] = []

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

            // Unmerged (an active, unresolved conflict) — porcelain v1's
            // documented XY combinations are DD/AU/UD/UA/DU/AA/UU: either
            // side being "U", or both sides matching on "A"/"D", covers all
            // seven without an explicit lookup table. Kept out of
            // staged/unstaged below — the old parsing put a "UU" line into
            // *both* of those (a non-blank, non-"?" char on both sides),
            // which is a worse fit than its own bucket.
            if indexStatus == "U" || workTreeStatus == "U"
                || (indexStatus == "A" && workTreeStatus == "A")
                || (indexStatus == "D" && workTreeStatus == "D") {
                conflicted.append(GitFileChange(path: path, status: "\(indexStatus)\(workTreeStatus)"))
                continue
            }

            if indexStatus != " " && indexStatus != "?" {
                staged.append(GitFileChange(path: path, status: String(indexStatus)))
            }
            if workTreeStatus != " " && workTreeStatus != "?" {
                unstaged.append(GitFileChange(path: path, status: String(workTreeStatus)))
            }
        }

        return (staged, unstaged, untracked, conflicted)
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

    /// `git push`, or `git push -u origin <branch>` the first time a branch
    /// is pushed (no upstream yet) — the same thing VS Code's Sync does.
    func push(at url: URL) async throws {
        do {
            _ = try await run(args: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], at: url)
            _ = try await run(args: ["push"], at: url)
            return
        } catch GitError.commandFailed(let message)
            where message.contains("no upstream") || message.contains("does not point to a branch") {
            // Fall through to the first-push path below. Any other failure
            // (index.lock, corrupt ref) must not silently retarget the
            // branch's upstream to origin.
        }
        let branch = try await currentBranch(at: url)
        guard !branch.isEmpty else {
            throw GitError.commandFailed("HEAD is detached — check out a branch before pushing.")
        }
        _ = try await run(args: ["push", "-u", "origin", branch], at: url)
    }

    func pull(at url: URL) async throws {
        _ = try await run(args: ["pull"], at: url)
    }

    func fetch(at url: URL) async throws {
        _ = try await run(args: ["fetch", "--prune"], at: url)
    }

    // MARK: - Stash

    func stashList(at url: URL) async throws -> [GitStash] {
        let output = try await run(args: ["stash", "list", "--format=%gd%x1f%s%x1f%at"], at: url)
        return Self.parseStashList(output)
    }

    /// Parses `git stash list --format=%gd%x1f%s%x1f%at` — unit-separator
    /// delimited so a stash message containing `|` can't break the parse.
    static func parseStashList(_ output: String) -> [GitStash] {
        var result: [GitStash] = []
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count >= 3 else { continue }
            // "stash@{3}" → 3
            let ref = parts[0]
            guard let open = ref.firstIndex(of: "{"), let close = ref.firstIndex(of: "}"),
                  open < close, let index = Int(ref[ref.index(after: open)..<close]) else { continue }
            let date = Date(timeIntervalSince1970: Double(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0)
            result.append(GitStash(index: index, message: parts[1], date: date))
        }
        return result
    }

    func stashPush(message: String, includeUntracked: Bool, at url: URL) async throws {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args += ["-m", trimmed] }
        // git exits 0 with this on stdout when there is nothing tracked to
        // stash (e.g. only untracked files without --include-untracked).
        let output = try await run(args: args, at: url)
        if output.contains("No local changes to save") {
            throw GitError.commandFailed("No local changes to save — untracked files need \"Stash Including Untracked\".")
        }
    }

    func stashApply(_ stash: GitStash, pop: Bool, at url: URL) async throws {
        _ = try await run(args: ["stash", pop ? "pop" : "apply", stash.ref], at: url)
    }

    func stashDrop(_ stash: GitStash, at url: URL) async throws {
        _ = try await run(args: ["stash", "drop", stash.ref], at: url)
    }

    // MARK: - Log

    /// Recent commits, optionally only those touching `path` (file history).
    func log(at url: URL, limit: Int, path: String? = nil) async throws -> [GitCommit] {
        // Unit-separator delimited (like `stashList`) so a subject containing
        // "|" can't shift the author/date columns.
        let format = "--format=%H%x1f%h%x1f%s%x1f%an%x1f%at"
        var args = ["log", format, "-" + String(limit)]
        if let path, !path.isEmpty { args += ["--follow", "--", path] }
        let output = try await run(args: args, at: url)

        var commits: [GitCommit] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "\u{1f}")
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
