// GitService+Advanced.swift
// Athena — amend, cherry-pick, tags, merge, rebase, hunk apply, line history.
// Swift 6, strict concurrency.

import Foundation

// MARK: - HunkAction

/// What to do with one diff hunk from the editor gutter.
enum GitHunkAction: Sendable, Equatable {
    case stage, unstage, revert
}

extension GitService {

    /// Environment that makes `--continue` commands accept the prepared
    /// message instead of opening an editor (no terminal is attached).
    private static let noEditor: [String: String] = [
        "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"
    ]

    // MARK: - Amend

    /// Amends HEAD with whatever is staged. An empty `message` keeps the
    /// existing one.
    func amend(message: String?, at url: URL) async throws {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            _ = try await run(args: ["commit", "--amend", "--no-edit"], at: url)
        } else {
            _ = try await run(args: ["commit", "--amend", "-m", trimmed], at: url)
        }
    }

    // MARK: - Cherry-pick

    func cherryPick(_ commit: String, at url: URL) async throws {
        _ = try await run(args: ["cherry-pick", commit], at: url, extraEnvironment: Self.noEditor)
    }

    func cherryPickAbort(at url: URL) async throws {
        _ = try await run(args: ["cherry-pick", "--abort"], at: url)
    }

    func cherryPickContinue(at url: URL) async throws {
        _ = try await run(args: ["cherry-pick", "--continue"], at: url, extraEnvironment: Self.noEditor)
    }

    // MARK: - Tags

    func tags(at url: URL) async throws -> [GitTag] {
        let output = try await run(args: ["tag", "-l", "--sort=-creatordate", "--format=" + GitParsing.tagFormat], at: url)
        return GitParsing.parseTags(output)
    }

    /// Lightweight tag, or annotated when `message` is non-empty.
    func createTag(_ name: String, at ref: String?, message: String?, in url: URL) async throws {
        var args = ["tag"]
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { args += ["-a", "-m", trimmed] }
        args.append(name)
        if let ref, !ref.isEmpty { args.append(ref) }
        _ = try await run(args: args, at: url)
    }

    func deleteTag(_ name: String, at url: URL) async throws {
        _ = try await run(args: ["tag", "-d", name], at: url)
    }

    // MARK: - Merge

    func merge(_ branch: String, at url: URL) async throws {
        _ = try await run(args: ["merge", "--no-edit", branch], at: url, extraEnvironment: Self.noEditor)
    }

    /// Finishes a conflicted merge once every file is resolved and staged.
    func mergeContinue(at url: URL) async throws {
        _ = try await run(args: ["commit", "--no-edit"], at: url, extraEnvironment: Self.noEditor)
    }

    func mergeAbort(at url: URL) async throws {
        _ = try await run(args: ["merge", "--abort"], at: url)
    }

    // MARK: - Rebase (non-interactive only)

    func rebase(onto branch: String, at url: URL) async throws {
        _ = try await run(args: ["rebase", branch], at: url, extraEnvironment: Self.noEditor)
    }

    func rebaseAbort(at url: URL) async throws {
        _ = try await run(args: ["rebase", "--abort"], at: url)
    }

    func rebaseContinue(at url: URL) async throws {
        _ = try await run(args: ["rebase", "--continue"], at: url, extraEnvironment: Self.noEditor)
    }

    // MARK: - Operation state

    func currentOperation(at url: URL) async -> GitOperation? {
        guard let out = try? await run(args: ["rev-parse", "--absolute-git-dir"], at: url) else { return nil }
        let dir = URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines))
        return GitParsing.detectOperation(gitDir: dir)
    }

    // MARK: - Hunks

    /// `git diff -U0` for one file, unstaged or staged.
    func zeroContextDiff(path: String, staged: Bool, at url: URL) async throws -> String {
        var args = ["diff", "-U0", "--no-color"]
        if staged { args.append("--cached") }
        args += ["--", path]
        return try await run(args: args, at: url)
    }

    /// Applies `patch` (a single-hunk, zero-context patch). The patch goes
    /// through a temp file so no stdin pipe is involved.
    func applyPatch(_ patch: String, action: GitHunkAction, at url: URL) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("athena-hunk-\(UUID().uuidString).patch")
        try patch.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        var args = ["apply", "--unidiff-zero"]
        switch action {
        case .stage:   args.append("--cached")
        case .unstage: args += ["--cached", "--reverse"]
        case .revert:  args.append("--reverse")
        }
        args.append(file.path)
        _ = try await run(args: args, at: url)
    }

    /// Stages/unstages/reverts the hunk at the working-tree `line` of `path`
    /// (repo-relative). Throws if no hunk matches.
    func applyHunk(_ action: GitHunkAction, path: String, line: Int, at url: URL) async throws {
        let staged = action == .unstage
        let diff = HunkPatch.splitRaw(try await zeroContextDiff(path: path, staged: staged, at: url))

        let targetLine: Int
        if staged {
            let unstaged = HunkPatch.splitRaw(try await zeroContextDiff(path: path, staged: false, at: url))
            guard let mapped = HunkPatch.indexLine(forWorktreeLine: line, unstagedHunks: unstaged.hunks) else {
                throw GitError.commandFailed("This line has unstaged edits; there is no staged hunk here.")
            }
            targetLine = mapped
        } else {
            targetLine = line
        }
        guard let index = HunkPatch.hunkIndex(containingNewLine: targetLine, in: diff.hunks),
              let patch = HunkPatch.patch(for: diff, hunkAt: index)
        else { throw GitError.commandFailed("No \(staged ? "staged" : "unstaged") change at this line.") }
        try await applyPatch(patch, action: action, at: url)
    }

    // MARK: - History

    /// Commits that touched lines `start...end` of `path` (`git log -L`).
    func lineHistory(path: String, start: Int, end: Int, limit: Int, at url: URL) async throws -> [GitCommit] {
        let range = "\(start),\(max(start, end)):\(path)"
        let output = try await run(
            args: ["log", GitParsing.logFormat, "-" + String(limit), "-s", "-L", range],
            at: url
        )
        return GitParsing.parseLog(output)
    }
}
