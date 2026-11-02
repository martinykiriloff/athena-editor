// GitParsing.swift
// Athena — pure, unit-testable parsers and algorithms for git depth features:
// tags, log with parents, commit-graph lanes, hunk patches, merge resolution.
// Swift 6, strict concurrency.

import Foundation

// MARK: - GitParsing

enum GitParsing {

    /// Unit separator used in all custom `--format` strings.
    static let sep = "\u{1f}"

    // MARK: - Tags

    /// Format string for `git tag -l --format=…`.
    static let tagFormat = "%(refname:short)%1f%(objectname:short)%1f%(objecttype)%1f%(contents:subject)"

    static func parseTags(_ output: String) -> [GitTag] {
        output.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: sep)
            guard parts.count >= 3, !parts[0].isEmpty else { return nil }
            return GitTag(
                name: parts[0],
                shortHash: parts[1],
                isAnnotated: parts[2] == "tag",
                subject: parts.count > 3 ? parts[3] : ""
            )
        }
    }

    // MARK: - Log

    /// `--format` used by `GitService.log`: hash, short hash, subject,
    /// author, unix time, parents (space separated), decorations.
    static let logFormat = "--format=%H%x1f%h%x1f%s%x1f%an%x1f%at%x1f%P%x1f%D"

    static func parseLog(_ output: String) -> [GitCommit] {
        var commits: [GitCommit] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: sep)
            guard parts.count >= 5 else { continue }
            let parents = parts.count > 5
                ? parts[5].split(separator: " ").map(String.init) : []
            let refs = parts.count > 6
                ? parts[6].components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            commits.append(GitCommit(
                hash: parts[0], shortHash: parts[1], message: parts[2], author: parts[3],
                date: Date(timeIntervalSince1970: Double(parts[4]) ?? 0),
                parents: parents, refs: refs
            ))
        }
        return commits
    }

    // MARK: - Operation state

    /// Which multi-step operation is paused, judged from marker files in the
    /// git directory. Rebase wins over the others (a rebase replays picks).
    static func detectOperation(gitDir: URL, fileManager: FileManager = .default) -> GitOperation? {
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: gitDir.appendingPathComponent(name).path)
        }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        return nil
    }
}

// MARK: - GitGraphLayout

/// Lane assignment for a commit graph. Input is newest-first, topologically
/// ordered (children before parents, as `git log --topo-order` emits).
enum GitGraphLayout {

    static func layout(_ commits: [GitCommit]) -> [GitGraphRow] {
        // `active[i]` is the hash lane `i` is waiting to reach, or nil if free.
        var active: [String?] = []
        var rows: [GitGraphRow] = []

        func freeLane() -> Int {
            if let i = active.firstIndex(where: { $0 == nil }) { return i }
            active.append(nil)
            return active.count - 1
        }

        for commit in commits {
            let incoming = active.indices.filter { active[$0] == commit.hash }
            let lane = incoming.first ?? freeLane()
            let before = Set(active.indices.filter { active[$0] != nil })

            // Every lane that was heading here ends at this node.
            for i in incoming { active[i] = nil }

            var outgoing: [Int] = []
            for (index, parent) in commit.parents.enumerated() {
                if let existing = active.firstIndex(where: { $0 == parent }) {
                    outgoing.append(existing)
                } else if index == 0 {
                    active[lane] = parent
                    outgoing.append(lane)
                } else {
                    let l = freeLane()
                    active[l] = parent
                    outgoing.append(l)
                }
            }

            let touched = Set(incoming).union(outgoing).union([lane])
            let pass = before.subtracting(incoming).filter { !touched.contains($0) }.sorted()
            // Trim trailing free lanes so the width shrinks again.
            while let last = active.last, last == nil { active.removeLast() }
            let used = (Set(pass).union(touched).max() ?? 0) + 1

            rows.append(GitGraphRow(
                hash: commit.hash, lane: lane,
                incomingLanes: incoming, outgoingLanes: outgoing,
                passThroughLanes: pass, laneCount: used
            ))
        }
        return rows
    }
}

// MARK: - HunkPatch

/// Builds single-hunk patches from a raw `git diff -U0` so a hunk can be
/// staged / unstaged / reverted with `git apply`. Works on raw text, not
/// `DiffHunk`, because the parsed form drops `\ No newline at end of file`.
enum HunkPatch {

    struct RawHunk: Equatable, Sendable {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        /// Header line plus body lines, each terminated with "\n".
        var text: String
    }

    struct RawDiff: Equatable, Sendable {
        /// Everything before the first `@@` (diff --git, index, ---, +++).
        var header: String
        var hunks: [RawHunk]
    }

    private static let headerPattern = try! NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
    )

    static func splitRaw(_ diff: String) -> RawDiff {
        var header = ""
        var hunks: [RawHunk] = []
        var current: RawHunk?
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        for line in lines {
            if line.hasPrefix("@@"), let h = parseHeader(line) {
                if let c = current { hunks.append(c) }
                current = h
                current?.text = line + "\n"
            } else if current != nil {
                current?.text += line + "\n"
            } else {
                header += line + "\n"
            }
        }
        if let c = current { hunks.append(c) }
        return RawDiff(header: header, hunks: hunks)
    }

    private static func parseHeader(_ line: String) -> RawHunk? {
        let ns = line as NSString
        guard let m = headerPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func int(_ i: Int, _ d: Int) -> Int {
            let r = m.range(at: i)
            return r.location == NSNotFound ? d : Int(ns.substring(with: r)) ?? d
        }
        return RawHunk(oldStart: int(1, 0), oldCount: int(2, 1), newStart: int(3, 0), newCount: int(4, 1), text: "")
    }

    /// The index of the hunk a gutter click on (1-based, new-side) `line`
    /// belongs to. A pure deletion (newCount == 0) is marked on the line
    /// after it, matching `classifyLineChanges`.
    static func hunkIndex(containingNewLine line: Int, in hunks: [RawHunk]) -> Int? {
        if let i = hunks.firstIndex(where: {
            $0.newCount > 0 && line >= $0.newStart && line < $0.newStart + $0.newCount
        }) { return i }
        return hunks.firstIndex(where: { $0.newCount == 0 && line == $0.newStart + 1 })
            ?? hunks.firstIndex(where: { $0.newCount == 0 && line == $0.newStart })
    }

    /// Complete patch text for one hunk, for `git apply --unidiff-zero`.
    static func patch(for diff: RawDiff, hunkAt index: Int) -> String? {
        guard diff.hunks.indices.contains(index) else { return nil }
        return diff.header + diff.hunks[index].text
    }

    /// Maps a working-tree line to the index line, given the *unstaged*
    /// `-U0` hunks (index → worktree). Nil if the line is itself inside an
    /// unstaged change (there is no stable index counterpart).
    static func indexLine(forWorktreeLine line: Int, unstagedHunks: [RawHunk]) -> Int? {
        var shift = 0
        for h in unstagedHunks {
            if h.newCount == 0 {
                if h.newStart < line { shift += h.newCount - h.oldCount }
                continue
            }
            let end = h.newStart + h.newCount - 1
            if line >= h.newStart && line <= end { return nil }
            if end < line { shift += h.newCount - h.oldCount }
        }
        return line - shift
    }
}

// MARK: - MergeResolution

/// Applies per-conflict choices to a conflicted file's text.
enum MergeResolution {

    /// Text with every region that has a choice replaced; regions without a
    /// choice keep their conflict markers. Regions are replaced back to
    /// front so earlier UTF-16 ranges stay valid.
    static func apply(
        choices: [Int: ConflictResolutionChoice],
        regions: [ConflictRegion],
        to text: String
    ) -> String {
        let result = NSMutableString(string: text)
        for (index, region) in regions.enumerated().reversed() {
            guard let choice = choices[index] else { continue }
            var replacement = region.resolvedText(for: choice)
            // `range` includes the closing marker's line terminator; keep one
            // unless the replacement is empty.
            let original = (text as NSString).substring(with: region.range)
            if !replacement.isEmpty, original.hasSuffix("\n") { replacement += "\n" }
            result.replaceCharacters(in: region.range, with: replacement)
        }
        return result as String
    }
}

// MARK: - GitHubParsing

/// Parsers for `gh` CLI JSON output.
enum GitHubParsing {

    /// `gh pr status --json …` → the current-branch PR, if any.
    static func parsePullRequestStatus(_ json: String) -> GitPullRequestInfo? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pr = root["currentBranch"] as? [String: Any],
              let number = pr["number"] as? Int
        else { return nil }
        return GitPullRequestInfo(
            number: number,
            title: pr["title"] as? String ?? "",
            state: pr["state"] as? String ?? "",
            url: pr["url"] as? String ?? "",
            headBranch: pr["headRefName"] as? String ?? "",
            isDraft: pr["isDraft"] as? Bool ?? false,
            reviewDecision: pr["reviewDecision"] as? String ?? ""
        )
    }

    /// `gh pr checks --json name,workflow,bucket,link`.
    static func parseChecks(_ json: String) -> [GitCICheck] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return GitCICheck(
                name: name,
                workflow: item["workflow"] as? String ?? "",
                bucket: item["bucket"] as? String ?? "pending",
                link: item["link"] as? String ?? ""
            )
        }
    }
}
