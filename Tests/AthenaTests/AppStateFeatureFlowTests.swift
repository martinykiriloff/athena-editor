// AppStateFeatureFlowTests.swift
// Athena — end-to-end flows through AppState, the exact entry points the
// SwiftUI views call, for the SFCC debugger, database and git Features.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

// MARK: - Helpers

private func makeTempDir(_ prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func runGit(_ args: [String], in dir: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = dir
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try p.run(); p.waitUntilExit()
}

private func waitUntil(_ condition: @MainActor () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if await MainActor.run(body: condition) { return }
        try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(20)))
    }
}

// MARK: - Debugger launch configs

@Suite("AppState SFCC launch configs")
@MainActor
struct AppStateSFCCLaunchTests {
    /// Note: `AppState.openWorkspace` writes the last-workspace setting and
    /// touches language servers, so these tests assign `workspace` directly.

    @Test func dwJSONWorkspaceOffersSFCCConfig() throws {
        let dir = try makeTempDir("athena-dw")
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"hostname":"localhost:1","username":"u","password":"p","code-version":"v1"}"#
            .write(to: dir.appendingPathComponent("dw.json"), atomically: true, encoding: .utf8)

        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        state.loadLaunchConfigs()
        #expect(state.launchConfigs.contains { $0.isSFCC })
        #expect(state.selectedLaunchConfigId != nil)
    }

    @Test func prophetEntryInLaunchJSONIsKeptAndNotDuplicated() throws {
        let dir = try makeTempDir("athena-launch")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        try #"{"configurations":[{"type":"prophet","request":"launch","name":"Attach to Sandbox","hostname":"h","username":"u","password":"p","codeversion":"v"}]}"#
            .write(to: dir.appendingPathComponent(".vscode/launch.json"), atomically: true, encoding: .utf8)
        try #"{"hostname":"other"}"#.write(to: dir.appendingPathComponent("dw.json"), atomically: true, encoding: .utf8)

        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        state.loadLaunchConfigs()
        let sfcc = state.launchConfigs.filter(\.isSFCC)
        #expect(sfcc.count == 1)
        #expect(sfcc.first?.name == "Attach to Sandbox")
        #expect(sfcc.first?.hostname == "h")
    }

    /// Unreachable sandbox: the session must fail fast with the error in the
    /// debug output and the state back to `.stopped` — never hang in
    /// `.launching`.
    @Test func unreachableSandboxFailsCleanly() async throws {
        let dir = try makeTempDir("athena-sfcc-launch")
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"hostname":"127.0.0.1:1","username":"u","password":"p"}"#
            .write(to: dir.appendingPathComponent("dw.json"), atomically: true, encoding: .utf8)

        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        state.loadLaunchConfigs()
        state.selectedLaunchConfigId = state.launchConfigs.first(where: \.isSFCC)?.id
        await state.startDebugging()
        #expect(state.debugState == .stopped)
        #expect(state.debugOutput.contains("Failed to start debugger"))
    }

    @Test func missingCredentialsIsReportedNotThrownAway() async throws {
        let dir = try makeTempDir("athena-sfcc-nocreds")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        state.launchConfigs = [LaunchConfig(type: "prophet", request: "launch", name: "x", program: "")]
        state.selectedLaunchConfigId = state.launchConfigs[0].id
        await state.startDebugging()
        #expect(state.debugState == .stopped)
        #expect(state.debugOutput.contains("no hostname"))
    }
}

// MARK: - Database flows

@Suite("AppState database flows")
@MainActor
struct AppStateDatabaseFlowTests {
    @Test func sqliteBrowseEditQueryDisconnect() async throws {
        let dir = try makeTempDir("athena-db-flow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("app.db")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        var conn = DBConnection(name: "app", type: .sqlite)
        conn.database = file.path
        let state = AppState()
        state.dbConnections = [conn]

        await state.connectAndBrowse(conn)
        #expect(state.dbBrowserErrorMessage == nil)
        #expect(state.dbBrowserConnectionId == conn.id)
        #expect(state.dbConnections[0].isConnected)
        #expect(state.dbBrowserTables.isEmpty)

        await state.runDBQuery("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        #expect(state.dbQueryErrorMessage == nil)
        await state.runDBQuery("INSERT INTO users (name) VALUES ('ann'), ('bob')")
        #expect(state.dbQueryResult?.affectedRows == 2)

        // The table list is loaded at connect time; reconnect picks up DDL.
        await state.connectAndBrowse(conn)
        #expect(state.dbBrowserTables.map(\.name) == ["users"])

        await state.loadDBTableData(state.dbBrowserTables[0])
        #expect(state.dbBrowserTableData?.rows.count == 2)

        await state.updateDBCell(rowId: 0, column: "name", newValue: .text("anna"))
        #expect(state.dbBrowserErrorMessage == nil)
        #expect(state.dbBrowserTableData?.rows[0].values["name"] == .text("anna"))

        await state.runDBQuery("SELECT name FROM users ORDER BY id")
        #expect(state.dbQueryResult?.rows.map { $0.values["name"] } == [.text("anna"), .text("bob")])

        // A data-changing statement reloads the browsed table.
        await state.runDBQuery("DELETE FROM users WHERE name = 'bob'")
        #expect(state.dbQueryResult?.affectedRows == 1)
        #expect(state.dbBrowserTableData?.rows.count == 1)

        await state.runDBQuery("SELECT * FROM nope")
        #expect(state.dbQueryErrorMessage != nil)
        #expect(state.dbQueryResult == nil)

        await state.disconnectDatabase(conn)
        #expect(state.dbConnections[0].isConnected == false)
        #expect(state.dbBrowserConnectionId == nil)
    }

    @Test func unsupportedEngineIsRefusedWithMessage() async {
        let state = AppState()
        let conn = DBConnection(name: "legacy", type: .mongodb)
        state.dbConnections = [conn]
        await state.connectAndBrowse(conn)
        #expect(state.dbBrowserConnectionId == nil)
        #expect(state.dbConnections[0].isConnected == false)
        #expect(state.statusMessage.contains("isn't supported"))
    }

    @Test func badSQLiteFileIsReported() async {
        let state = AppState()
        var conn = DBConnection(name: "x", type: .sqlite)
        conn.database = "/definitely/missing.db"
        state.dbConnections = [conn]
        await state.connectAndBrowse(conn)
        #expect(state.dbBrowserConnectionId == nil)
        #expect(state.statusMessage.contains("Couldn't connect"))
    }
}

// MARK: - Git flows

@Suite("AppState git flows", .serialized)
@MainActor
struct AppStateGitFlowTests {
    private func makeRepo() throws -> URL {
        let dir = try makeTempDir("athena-git-flow")
        try runGit(["init", "-q", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@example.com"], in: dir)
        try runGit(["config", "user.name", "Test"], in: dir)
        try runGit(["config", "commit.gpgsign", "false"], in: dir)
        try "one\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-q", "-m", "init"], in: dir)
        return dir
    }

    @Test func commitStashHistoryAndSyncErrors() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)

        await state.refreshGitStatus()
        #expect(state.gitStatus.branch == "main")
        #expect(state.gitStatus.isClean)
        #expect(state.gitStashes.isEmpty)

        // Empty message → nothing happens, no error.
        state.commitMessage = "   "
        await state.commitStaged()
        #expect(state.gitStatus.isClean)

        try "two\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await state.refreshGitStatus()
        #expect(state.gitStatus.unstaged.map(\.path) == ["a.txt"])

        // Stash uses the message box, then clears it.
        state.commitMessage = "half done"
        await state.stashChanges(includeUntracked: false)
        #expect(state.commitMessage.isEmpty)
        #expect(state.gitStatus.isClean)
        #expect(state.gitStashes.count == 1)
        #expect(state.gitStashes[0].message.hasSuffix("half done"))

        await state.applyStash(state.gitStashes[0], pop: true)
        #expect(state.gitStashes.isEmpty)
        #expect(state.gitStatus.unstaged.count == 1)

        try await state.gitService.stage(["a.txt"], at: dir)
        state.commitMessage = "second\n\nbody"
        await state.commitStaged()
        #expect(state.commitMessage.isEmpty)
        #expect(state.statusMessage == "Committed: second")
        #expect(state.gitStatus.isClean)

        // File history switches the panel and filters the log.
        await state.showFileHistory(path: "a.txt")
        #expect(state.gitPanelShowsHistory)
        #expect(state.commitHistory.map(\.message) == ["second", "init"])
        try "b\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await state.gitService.stage(["b.txt"], at: dir)
        state.commitMessage = "add b"
        await state.commitStaged()
        await state.showFileHistory(path: "b.txt")
        #expect(state.commitHistory.map(\.message) == ["add b"])
        await state.clearFileHistoryFilter()
        #expect(state.commitHistoryPath == nil)
        #expect(state.commitHistory.count == 3)

        // No remote: push/pull/fetch fail with git's message, never hang,
        // and the syncing flag is released.
        await state.gitPush()
        #expect(state.statusMessage.hasPrefix("Push failed:"))
        #expect(state.isGitSyncing == false)
        await state.gitPull()
        #expect(state.statusMessage.hasPrefix("Pull failed:"))
        // `git fetch` with no remotes is a no-op that exits 0.
        await state.gitFetch()
        #expect(state.statusMessage == "Fetch complete")

        // Drop a stash.
        try "three\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        state.commitMessage = ""
        await state.stashChanges(includeUntracked: false)
        #expect(state.gitStashes.count == 1)
        await state.dropStash(state.gitStashes[0])
        #expect(state.gitStashes.isEmpty)
        #expect(state.statusMessage == "Stash dropped")
    }

    /// A stash pushed outside Athena shifts every index; a row from the old
    /// list must still act on the stash it displays.
    @Test func staleStashRowActsOnTheRightStash() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        for n in 1...2 {
            try "v\(n)\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            state.commitMessage = "stash \(n)"
            await state.refreshGitStatus()
            await state.stashChanges(includeUntracked: false)
        }
        let rowForStash1 = state.gitStashes.first { $0.message.hasSuffix("stash 1") }!
        // External stash: indexes shift by one.
        try "v3\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try runGit(["stash", "push", "-q", "-m", "external"], in: dir)
        await state.dropStash(rowForStash1)
        #expect(state.statusMessage == "Stash dropped")
        #expect(state.gitStashes.map(\.message).contains { $0.hasSuffix("external") })
        #expect(state.gitStashes.map(\.message).contains { $0.hasSuffix("stash 2") })
        #expect(!state.gitStashes.map(\.message).contains { $0.hasSuffix("stash 1") })
    }

    @Test func stashOnUntrackedOnlyTreeIsRefused() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        try "new\n".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        await state.refreshGitStatus()
        state.commitMessage = "keep me"
        await state.stashChanges(includeUntracked: false)
        #expect(state.commitMessage == "keep me")
        #expect(state.gitStashes.isEmpty)
        #expect(state.statusMessage.contains("Nothing tracked"))
    }

    @Test func switchingWorkspaceResetsGitPanelState() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        await state.showFileHistory(path: "a.txt")
        state.commitMessage = "typed"
        // A non-repository folder: status fails, nothing from the old repo may survive.
        let plain = try makeTempDir("athena-plain")
        defer { try? FileManager.default.removeItem(at: plain) }
        state.workspace = WorkspaceModel(rootURL: plain)
        await state.refreshGitStatus()
        #expect(state.gitStashes.isEmpty)
        #expect(state.gitStatus.branch.isEmpty)
    }

    @Test func commitFailureIsSurfaced() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: dir)
        await state.refreshGitStatus()
        // Nothing staged: git refuses; the message must survive.
        state.commitMessage = "nothing to commit"
        await state.commitStaged()
        #expect(state.statusMessage.hasPrefix("Commit failed:"))
        #expect(state.commitMessage == "nothing to commit")
    }
}

// MARK: - Full cartridge deploy reporting

@Suite("AppState cartridge deploy", .serialized)
@MainActor
struct AppStateCartridgeDeployTests {
    private func makeWorkspace(cartridges: [String]) throws -> URL {
        let root = try makeTempDir("athena-deploy")
        for name in cartridges {
            let dir = root.appendingPathComponent("cartridges/\(name)/cartridge/controllers")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "// \(name)".write(to: dir.appendingPathComponent("Home.js"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func connection() -> SFCCConnection {
        SFCCConnection(name: "009", hostname: "sandbox.test", username: "u", password: "p",
                       codeVersion: "martin", cartridgesPath: "cartridges", isActive: true)
    }

    /// A hibernated on-demand sandbox answers 521. Every cartridge fails,
    /// and the user must be able to see which ones and, above all, why.
    @Test func aSleepingSandboxReportsWhyInTheOutputPanel() async throws {
        let root = try makeWorkspace(cartridges: ["app_ana", "int_core"])
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(sfccService: SFCCService(transport: { _ in (Data(), 521) }))
        state.workspace = WorkspaceModel(rootURL: root)
        state.sfccConnections = [connection()]

        await state.uploadAllCartridges()

        // The panel opens on the Output tab without being asked.
        #expect(state.showBottomPanel)
        #expect(state.activeBottomPanel == .output)

        // Each cartridge is named, with a reason a person can act on.
        #expect(state.scriptOutput.contains("app_ana"))
        #expect(state.scriptOutput.contains("int_core"))
        #expect(state.scriptOutput.contains("hibernated"))
        #expect(state.scriptOutput.contains("HTTP 521"))
        #expect(state.scriptOutput.contains("── Done: 0 uploaded, 2 failed ──"))
        #expect(state.scriptOutput.contains("sandbox.test"))
        #expect(state.scriptOutput.contains("martin"))

        // And the same outcome is recorded in the Uploads history.
        #expect(state.sfccUploadLog.count == 2)
        #expect(state.sfccUploadLog.allSatisfy { $0.kind == .cartridge })
        #expect(state.sfccUploadLog.allSatisfy { $0.failureMessage?.contains("521") == true })
        #expect(state.statusMessage.contains("2 failed"))
    }

    @Test func aWorkingSandboxListsEveryCartridgeUploaded() async throws {
        let root = try makeWorkspace(cartridges: ["app_ana", "int_core", "plugin_seo"])
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(sfccService: SFCCService(transport: { _ in (Data(), 201) }))
        state.workspace = WorkspaceModel(rootURL: root)
        state.sfccConnections = [connection()]

        await state.uploadAllCartridges()

        for name in ["app_ana", "int_core", "plugin_seo"] {
            #expect(state.scriptOutput.contains("✓ \(name)"))
        }
        #expect(state.scriptOutput.contains("── Done: 3 uploaded, auto-upload is on ──"))
        #expect(state.sfccUploadLog.allSatisfy { $0.failureMessage == nil })
        #expect(state.statusMessage.contains("auto-upload on"))
    }

    @Test func credentialAndVersionFailuresExplainThemselves() {
        #expect(SFCCError.explain(401).contains("credentials"))
        #expect(SFCCError.explain(403).contains("permission"))
        #expect(SFCCError.explain(404).contains("code version"))
        #expect(SFCCError.explain(507).contains("storage"))
        #expect(SFCCError.explain(521).contains("hibernated"))
        #expect(SFCCError.explain(418) == "HTTP 418")
    }

    @Test func noActiveSandboxSaysSoInsteadOfDoingNothing() async {
        let state = AppState()
        state.sfccConnections = []
        await state.uploadAllCartridges()
        #expect(state.statusMessage.contains("No active SFCC sandbox"))
        #expect(state.isUploadingCartridges == false)
    }
}
