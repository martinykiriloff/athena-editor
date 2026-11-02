// GitDepthTests.swift
// Athena — tests for git depth: parsers, graph lanes, hunk patches, merge
// resolution, and integration tests against a temp repository.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

// MARK: - Helpers

private func makeRepo() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("athena-gitdepth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try sh(["init", "-q", "-b", "main"], dir)
    try sh(["config", "user.email", "t@example.com"], dir)
    try sh(["config", "user.name", "Test"], dir)
    try sh(["config", "commit.gpgsign", "false"], dir)
    return dir
}

@discardableResult
private func sh(_ args: [String], _ dir: URL) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = dir
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private func write(_ name: String, _ text: String, _ dir: URL) throws {
    try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

private func commit(_ name: String, _ text: String, _ message: String, _ dir: URL) throws {
    try write(name, text, dir)
    try sh(["add", "."], dir)
    try sh(["commit", "-q", "-m", message], dir)
}

private func c(_ hash: String, _ parents: [String]) -> GitCommit {
    GitCommit(hash: hash, shortHash: hash, message: hash, author: "a", date: Date(), parents: parents)
}

// MARK: - Parsers

@Suite("Git depth parsers")
struct GitDepthParserTests {
    @Test func parsesTags() {
        let out = "v1\u{1f}abc1234\u{1f}commit\u{1f}first\nv2\u{1f}def5678\u{1f}tag\u{1f}Release 2\n"
        let tags = GitParsing.parseTags(out)
        #expect(tags.count == 2)
        #expect(tags[0] == GitTag(name: "v1", shortHash: "abc1234", isAnnotated: false, subject: "first"))
        #expect(tags[1].isAnnotated)
    }

    @Test func parsesLogWithParentsAndRefs() {
        let line = "H1\u{1f}h1\u{1f}Merge x\u{1f}Ann\u{1f}1700000000\u{1f}P1 P2\u{1f}HEAD -> main, tag: v1\n"
        let commits = GitParsing.parseLog(line + "H2\u{1f}h2\u{1f}root\u{1f}Bob\u{1f}1\u{1f}\u{1f}\n")
        #expect(commits.count == 2)
        #expect(commits[0].parents == ["P1", "P2"])
        #expect(commits[0].refs == ["HEAD -> main", "tag: v1"])
        #expect(commits[1].parents.isEmpty)
        #expect(commits[1].refs.isEmpty)
    }

    @Test func parsesGitHubPullRequestStatus() {
        let json = #"{"createdBy":[],"needsReview":[],"currentBranch":{"number":42,"title":"Add x","state":"OPEN","url":"https://github.com/o/r/pull/42","headRefName":"feat","isDraft":false,"reviewDecision":"APPROVED"}}"#
        let pr = GitHubParsing.parsePullRequestStatus(json)
        #expect(pr?.number == 42)
        #expect(pr?.reviewDecision == "APPROVED")
        #expect(GitHubParsing.parsePullRequestStatus(#"{"currentBranch":null}"#) == nil)
        #expect(GitHubParsing.parsePullRequestStatus("garbage") == nil)
    }

    @Test func parsesGitHubChecks() {
        let json = #"[{"name":"build","workflow":"CI","bucket":"pass","link":"https://x/1"},{"name":"lint","workflow":"CI","bucket":"fail","link":""}]"#
        let checks = GitHubParsing.parseChecks(json)
        #expect(checks.map(\.bucket) == ["pass", "fail"])
        #expect(GitHubParsing.parseChecks("nope").isEmpty)
    }
}

// MARK: - Graph

@Suite("GitGraphLayout")
struct GitGraphLayoutTests {
    @Test func linearHistoryStaysInLaneZero() {
        let rows = GitGraphLayout.layout([c("C", ["B"]), c("B", ["A"]), c("A", [])])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.allSatisfy { $0.laneCount == 1 })
        #expect(rows[2].outgoingLanes.isEmpty)
        #expect(rows[1].incomingLanes == [0])
    }

    @Test func branchAndMergeUseTwoLanes() {
        // M merges F (side) into main; both descend from A.
        //  M (P: A2, F)
        //  F (P: A)
        //  A2 (P: A)
        //  A
        let rows = GitGraphLayout.layout([c("M", ["A2", "F"]), c("F", ["A"]), c("A2", ["A"]), c("A", [])])
        #expect(rows[0].lane == 0)
        #expect(rows[0].outgoingLanes == [0, 1])
        #expect(rows[1].lane == 1)          // F sits on the side lane
        #expect(rows[1].passThroughLanes == [0])
        #expect(rows[2].lane == 0)
        // A2 joins the lane already waiting for A: lane 1 keeps running
        // through this row and A2's line bends into it.
        #expect(rows[2].passThroughLanes == [1])
        #expect(rows[2].outgoingLanes == [1])
        #expect(rows[3].lane == 1)
        #expect(rows[3].laneCount == 2)
    }

    @Test func unseenChildStartsNewLane() {
        // Two independent tips: X then Y, both parented to R.
        let rows = GitGraphLayout.layout([c("X", ["R"]), c("Y", ["R"]), c("R", [])])
        #expect(rows[0].lane == 0)
        #expect(rows[1].lane == 1)
        #expect(rows[1].outgoingLanes == [0])   // Y bends into the lane already waiting for R
        #expect(rows[2].lane == 0)
    }
}

// MARK: - Hunk patches

@Suite("HunkPatch")
struct HunkPatchTests {
    private let diff = """
    diff --git a/f.txt b/f.txt
    index 111..222 100644
    --- a/f.txt
    +++ b/f.txt
    @@ -2 +2 @@
    -two
    +TWO
    @@ -5,0 +6,2 @@
    +new1
    +new2
    @@ -9 +10,0 @@
    -nine
    \\ No newline at end of file

    """

    @Test func splitsHeaderAndHunks() {
        let raw = HunkPatch.splitRaw(diff)
        #expect(raw.header.contains("+++ b/f.txt"))
        #expect(raw.hunks.count == 3)
        #expect(raw.hunks[0].oldCount == 1 && raw.hunks[0].newCount == 1)
        #expect(raw.hunks[1].newStart == 6 && raw.hunks[1].newCount == 2)
        #expect(raw.hunks[2].newCount == 0)
        #expect(raw.hunks[2].text.contains("\\ No newline at end of file"))
    }

    @Test func findsHunkForLine() {
        let hunks = HunkPatch.splitRaw(diff).hunks
        #expect(HunkPatch.hunkIndex(containingNewLine: 2, in: hunks) == 0)
        #expect(HunkPatch.hunkIndex(containingNewLine: 7, in: hunks) == 1)
        #expect(HunkPatch.hunkIndex(containingNewLine: 11, in: hunks) == 2)   // deletion marker is on the next line
        #expect(HunkPatch.hunkIndex(containingNewLine: 4, in: hunks) == nil)
    }

    @Test func patchIsHeaderPlusOneHunk() throws {
        let raw = HunkPatch.splitRaw(diff)
        let patch = try #require(HunkPatch.patch(for: raw, hunkAt: 1))
        #expect(patch.hasPrefix("diff --git"))
        #expect(patch.contains("+new1") && !patch.contains("+TWO"))
        #expect(patch.hasSuffix("+new2\n"))
        #expect(HunkPatch.patch(for: raw, hunkAt: 9) == nil)
    }

    @Test func mapsWorktreeLineToIndexLine() {
        let hunks = HunkPatch.splitRaw(diff).hunks
        #expect(HunkPatch.indexLine(forWorktreeLine: 1, unstagedHunks: hunks) == 1)
        #expect(HunkPatch.indexLine(forWorktreeLine: 2, unstagedHunks: hunks) == nil)  // inside an unstaged change
        // After the +2 insertion (new lines 6-7) a worktree line 8 is index line 6.
        #expect(HunkPatch.indexLine(forWorktreeLine: 8, unstagedHunks: Array(hunks.prefix(2))) == 6)
    }
}

// MARK: - Merge resolution

@Suite("MergeResolution")
struct MergeResolutionTests {
    private let text = "a\n<<<<<<< HEAD\nours1\n=======\ntheirs1\n>>>>>>> feat\nmid\n<<<<<<< HEAD\nours2\n=======\ntheirs2\n>>>>>>> feat\nz\n"

    @Test func resolvesEachRegionIndependently() {
        let regions = ConflictParser.parse(text)
        #expect(regions.count == 2)
        let out = MergeResolution.apply(choices: [0: .ours, 1: .theirs], regions: regions, to: text)
        #expect(out == "a\nours1\nmid\ntheirs2\nz\n")
    }

    @Test func bothAndUnresolved() {
        let regions = ConflictParser.parse(text)
        let both = MergeResolution.apply(choices: [0: .both], regions: regions, to: text)
        #expect(both.hasPrefix("a\nours1\ntheirs1\nmid\n<<<<<<< HEAD\nours2"))
        #expect(MergeResolution.apply(choices: [:], regions: regions, to: text) == text)
    }
}

// MARK: - Integration

@Suite("GitService advanced (temp repo)")
struct GitServiceAdvancedTests {
    private let git = GitService()

    @Test func amendReplacesHeadCommit() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        try commit("a.txt", "1\n", "first", dir)
        try write("a.txt", "2\n", dir)
        try sh(["add", "."], dir)
        try await git.amend(message: "first (amended)", at: dir)
        let log = try await git.log(at: dir, limit: 10)
        #expect(log.map(\.message) == ["first (amended)"])
        // No message keeps the old one.
        try write("a.txt", "3\n", dir); try sh(["add", "."], dir)
        try await git.amend(message: nil, at: dir)
        #expect(try await git.log(at: dir, limit: 10).map(\.message) == ["first (amended)"])
    }

    @Test func createListDeleteTags() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        try commit("a.txt", "1\n", "first", dir)
        try await git.createTag("v1", at: nil, message: nil, in: dir)
        try await git.createTag("v2", at: "HEAD", message: "Release two", in: dir)
        let tags = try await git.tags(at: dir)
        #expect(Set(tags.map(\.name)) == ["v1", "v2"])
        #expect(tags.first { $0.name == "v2" }?.isAnnotated == true)
        #expect(tags.first { $0.name == "v1" }?.isAnnotated == false)
        try await git.deleteTag("v1", at: dir)
        #expect(try await git.tags(at: dir).map(\.name) == ["v2"])
    }

    @Test func cherryPickBringsCommitOver() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        try commit("a.txt", "1\n", "base", dir)
        try sh(["checkout", "-q", "-b", "feat"], dir)
        try commit("b.txt", "b\n", "add b", dir)
        let hash = try #require(try await git.log(at: dir, limit: 1).first?.hash)
        try sh(["checkout", "-q", "main"], dir)
        try await git.cherryPick(hash, at: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
        #expect(try await git.log(at: dir, limit: 1).first?.message == "add b")
    }

    @Test func cherryPickConflictThenAbort() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        try commit("a.txt", "1\n", "base", dir)
        try sh(["checkout", "-q", "-b", "feat"], dir)
        try commit("a.txt", "feat\n", "feat edit", dir)
        let hash = try #require(try await git.log(at: dir, limit: 1).first?.hash)
        try sh(["checkout", "-q", "main"], dir)
        try commit("a.txt", "main\n", "main edit", dir)
        await #expect(throws: GitError.self) { try await git.cherryPick(hash, at: dir) }
        #expect(await git.currentOperation(at: dir) == .cherryPick)
        try await git.cherryPickAbort(at: dir)
        #expect(await git.currentOperation(at: dir) == nil)
    }

    @Test func mergeCleanAndConflictAbort() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        try commit("a.txt", "1\n", "base", dir)
        try sh(["checkout", "-q", "-b", "feat"], dir)
        try commit("b.txt", "b\n", "add b", dir)
        try sh(["checkout", "-q", "main"], dir)
        try commit("c.txt", "c\n", "add c", dir)
        try await git.merge("feat", at: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
        #expect(await git.currentOperation(at: dir) == nil)

        // Conflict
        try sh(["checkout", "-q", "-b", "x"], dir)
        try commit("a.txt", "x\n", "x edit", dir)
        try sh(["checkout", "-q", "main"], dir)
        try commit("a.txt", "m\n", "m edit", dir)
        await #expect(throws: GitError.self) { try await git.merge("x", at: dir) }
        #expect(await git.currentOperation(at: dir) == .merge)
        let status = try await git.status(at: dir)
        #expect(status.conflicted.map(\.path) == ["a.txt"])
        try await git.mergeAbort(at: dir)
        #expect(await git.currentOperation(at: dir) == nil)
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "m\n")
    }

    @Test func rebaseCleanConflictContinueAndAbort() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        try commit("a.txt", "1\n", "base", dir)
        try sh(["checkout", "-q", "-b", "feat"], dir)
        try commit("a.txt", "feat\n", "feat edit", dir)
        try sh(["checkout", "-q", "main"], dir)
        try commit("b.txt", "b\n", "main adds b", dir)
        try sh(["checkout", "-q", "feat"], dir)
        try await git.rebase(onto: "main", at: dir)
        #expect(try await git.log(at: dir, limit: 3).map(\.message) == ["feat edit", "main adds b", "base"])

        // Conflict: abort path.
        try sh(["checkout", "-q", "main"], dir)
        try commit("a.txt", "main-a\n", "main edits a", dir)
        try sh(["checkout", "-q", "feat"], dir)
        await #expect(throws: GitError.self) { try await git.rebase(onto: "main", at: dir) }
        #expect(await git.currentOperation(at: dir) == .rebase)
        try await git.rebaseAbort(at: dir)
        #expect(await git.currentOperation(at: dir) == nil)

        // Conflict: resolve + continue path.
        await #expect(throws: GitError.self) { try await git.rebase(onto: "main", at: dir) }
        try write("a.txt", "resolved\n", dir)
        try await git.stage(["a.txt"], at: dir)
        try await git.rebaseContinue(at: dir)
        #expect(await git.currentOperation(at: dir) == nil)
        #expect(try await git.log(at: dir, limit: 1).first?.message == "feat edit")
    }

    @Test func hunkStageUnstageRevert() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try commit("f.txt", original, "base", dir)
        var lines = (1...20).map { "line \($0)" }
        lines[1] = "CHANGED 2"
        lines[15] = "CHANGED 16"
        try write("f.txt", lines.joined(separator: "\n") + "\n", dir)

        // Stage only the first hunk (worktree line 2).
        try await git.applyHunk(.stage, path: "f.txt", line: 2, at: dir)
        let cached = try await git.diff(path: "f.txt", staged: true, at: dir)
        #expect(cached.contains("+CHANGED 2") && !cached.contains("CHANGED 16"))
        let unstaged = try await git.diff(path: "f.txt", staged: false, at: dir)
        #expect(unstaged.contains("+CHANGED 16") && !unstaged.contains("CHANGED 2\n"))

        // Unstage it again.
        try await git.applyHunk(.unstage, path: "f.txt", line: 2, at: dir)
        #expect(try await git.diff(path: "f.txt", staged: true, at: dir).isEmpty)

        // Revert the second hunk in the working tree.
        try await git.applyHunk(.revert, path: "f.txt", line: 16, at: dir)
        let content = try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8)
        #expect(content.contains("line 16") && content.contains("CHANGED 2"))

        // No change at a clean line.
        await #expect(throws: GitError.self) { try await git.applyHunk(.stage, path: "f.txt", line: 10, at: dir) }
    }

    @Test func hunkOnFileWithoutTrailingNewline() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        try commit("n.txt", "a\nb\nc", "base", dir)
        try write("n.txt", "a\nB\nc", dir)
        try await git.applyHunk(.stage, path: "n.txt", line: 2, at: dir)
        #expect(try await git.diff(path: "n.txt", staged: true, at: dir).contains("+B"))
    }

    @Test func lineHistoryAndFileHistory() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        try commit("f.txt", "a\nb\nc\n", "base", dir)
        try commit("f.txt", "a\nB\nc\n", "edit line 2", dir)
        try commit("f.txt", "a\nB\nC\n", "edit line 3", dir)
        let line2 = try await git.lineHistory(path: "f.txt", start: 2, end: 2, limit: 10, at: dir)
        #expect(line2.map(\.message) == ["edit line 2", "base"])
        let file = try await git.log(at: dir, limit: 10, path: "f.txt")
        #expect(file.count == 3)
    }

    @Test func logAllBranchesCarriesParents() async throws {
        let dir = try makeRepo(); defer { try? FileManager.default.removeItem(at: dir) }
        try commit("a.txt", "1\n", "base", dir)
        try sh(["checkout", "-q", "-b", "side"], dir)
        try commit("b.txt", "b\n", "side", dir)
        try sh(["checkout", "-q", "main"], dir)
        try commit("c.txt", "c\n", "main", dir)
        let commits = try await git.log(at: dir, limit: 10, allBranches: true)
        #expect(commits.count == 3)
        #expect(commits.allSatisfy { $0.message == "base" ? $0.parents.isEmpty : $0.parents.count == 1 })
        let rows = GitGraphLayout.layout(commits)
        #expect(rows.map(\.laneCount).max() == 2)
    }
}
