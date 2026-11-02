// SafetyAndAccessibilityTests.swift
// Athena — workspace trust gating, settings profiles, update verification, crash log, themes.
// Swift 6, strict concurrency.

import Testing
import Foundation
import AppKit
@testable import Athena

private func tempDir(_ name: String = UUID().uuidString) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("athena-test-\(name)")
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Workspace Trust

@Suite("Workspace Trust")
struct WorkspaceTrustTests {

    @Test func onlyTrustedStateAllowsAnyAction() {
        for action in TrustedAction.allCases {
            #expect(TrustPolicy.isAllowed(action, state: .trusted))
            #expect(!TrustPolicy.isAllowed(action, state: .restricted))
            #expect(!TrustPolicy.isAllowed(action, state: .undecided))
        }
    }

    @Test func recordKeepsOneDecisionPerPath() {
        var record = WorkspaceTrustRecord()
        record.set(.trusted, for: "/a")
        record.set(.restricted, for: "/a")
        #expect(record.state(for: "/a") == .restricted)
        #expect(record.trusted.isEmpty)
        #expect(record.state(for: "/b") == .undecided)
    }

    @Test func decisionPersistsPerCanonicalPath() async {
        let dir = tempDir()
        let settings = SettingsService(directory: dir.appendingPathComponent("settings"))
        let service = WorkspaceTrustService(settings: settings)
        let project = dir.appendingPathComponent("proj")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        await service.set(.trusted, for: project)
        let again = WorkspaceTrustService(settings: SettingsService(directory: dir.appendingPathComponent("settings")))
        #expect(await again.state(for: project.appendingPathComponent("../proj")) == .trusted)
        #expect(await again.state(for: dir) == .undecided)
    }

    @Test func insideWorkspaceDetectionIsPathBoundaryAware() {
        let ws = URL(fileURLWithPath: "/tmp/ws")
        #expect(TrustPolicy.isInsideWorkspace(executablePath: "/tmp/ws/node_modules/.bin/tsserver", workspace: ws))
        #expect(!TrustPolicy.isInsideWorkspace(executablePath: "/tmp/ws-other/bin/x", workspace: ws))
        #expect(!TrustPolicy.isInsideWorkspace(executablePath: "/opt/homebrew/bin/x", workspace: ws))
    }

    @MainActor @Test func requireTrustBlocksUntilTrusted() async {
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: tempDir())
        state.trust.state = .undecided
        #expect(!state.isWorkspaceTrusted)
        #expect(!state.requireTrust(for: .task))
        #expect(state.statusMessage.contains("Restricted Mode"))
        #expect(state.scriptOutput.contains("[trust]"))

        state.trust.state = .restricted
        #expect(!state.requireTrust(for: .debug))
        state.trust.state = .trusted
        #expect(state.requireTrust(for: .sfccUpload))
        #expect(state.isWorkspaceTrusted)
    }

    @MainActor @Test func taskIsRefusedInRestrictedMode() async {
        let state = AppState()
        state.workspace = WorkspaceModel(rootURL: tempDir())
        state.trust.state = .restricted
        state.runWorkspaceTask(label: "build")
        #expect(state.taskCenter.runningLabel == nil)
        #expect(state.scriptOutput.contains("Running tasks is disabled"))
    }
}

// MARK: - Settings profiles

@Suite("Settings profile")
struct SettingsProfileTests {

    @Test func roundTripsSettingsAndKeybindingsButNotSecretsOrTrust() async throws {
        let src = tempDir()
        let settings = SettingsService(directory: src.appendingPathComponent("settings"))
        try await settings.setValue(16.0, for: "fontSize")
        try await settings.setValue("athena-light", for: "theme")
        try await settings.setValue(["a": 1, "b": 2], for: "custom")
        try await settings.setValue("sk-secret", for: "claudeApiKey")
        try await settings.setValue(WorkspaceTrustRecord(trusted: ["/x"], restricted: []), for: WorkspaceTrustService.settingsKey)
        let kb = src.appendingPathComponent("keybindings.json")
        try #"[{"key":"cmd+j","command":"workbench.action.files.save"}]"#.write(to: kb, atomically: true, encoding: .utf8)

        let file = src.appendingPathComponent("p.athena-profile")
        try await SettingsProfileService(settings: settings, keybindingsURL: kb).export(to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("sk-secret"))
        #expect(!text.contains("workspaceTrust"))

        let dst = tempDir()
        let target = SettingsService(directory: dst.appendingPathComponent("settings"))
        let dstKB = dst.appendingPathComponent("keybindings.json")
        let n = try await SettingsProfileService(settings: target, keybindingsURL: dstKB).importProfile(from: file)
        #expect(n == 3)
        #expect(await target.fontSize() == 16.0)
        #expect(await target.theme() == "athena-light")
        #expect(await target.value(for: "custom", default: [String: Int]()) == ["a": 1, "b": 2])
        #expect(await target.claudeApiKey() == "")
        #expect(try String(contentsOf: dstKB, encoding: .utf8).contains("cmd+j"))
    }

    @Test func importCannotGrantTrustOrEscapeTheDirectory() async throws {
        let profile = SettingsProfile(createdAt: .now, settings: [
            WorkspaceTrustService.settingsKey: .object(["trusted": .array([.string("/evil")])]),
            "../escape": .string("x"),
            "claudeApiKey": .string("k"),
            "ok": .string("fine"),
        ])
        let dir = tempDir()
        let settings = SettingsService(directory: dir.appendingPathComponent("settings"))
        let written = try await SettingsProfileService(settings: settings, keybindingsURL: dir.appendingPathComponent("kb.json")).apply(profile)
        #expect(written == 1)
        #expect(await settings.allKeys() == ["ok"])
    }

    @Test func rejectsForeignAndNewerFiles() throws {
        #expect(throws: SettingsProfile.ProfileError.notAProfile) {
            _ = try SettingsProfile.decode(Data(#"{"hello":1}"#.utf8))
        }
        var newer = SettingsProfile(createdAt: .now, settings: [:])
        newer.version = 99
        let data = try SettingsProfile.encoder().encode(newer)
        #expect(throws: SettingsProfile.ProfileError.unsupportedVersion(99)) {
            _ = try SettingsProfile.decode(data)
        }
    }
}

// MARK: - Update verification

@Suite("Update verification")
struct UpdateVerifierTests {
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func file(_ content: String) throws -> URL {
        let url = tempDir().appendingPathComponent("Athena.zip")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func hashesKnownVector() throws {
        #expect(try UpdateVerifier.sha256Hex(of: file("abc")) == abcDigest)
    }

    @Test func acceptsBareAndShasumFormats() throws {
        let f = try file("abc")
        try UpdateVerifier.verifyChecksum(file: f, checksumText: abcDigest + "\n", assetName: "Athena.zip")
        try UpdateVerifier.verifyChecksum(file: f, checksumText: "\(abcDigest.uppercased())  Athena.zip\n", assetName: "Athena.zip")
        try UpdateVerifier.verifyChecksum(file: f, checksumText: "\(String(repeating: "0", count: 64))  other.zip\n\(abcDigest) *Athena.zip", assetName: "Athena.zip")
    }

    @Test func refusesMismatchMissingAndMalformed() throws {
        let f = try file("abd")
        #expect(throws: (any Error).self) {
            try UpdateVerifier.verifyChecksum(file: f, checksumText: abcDigest, assetName: "Athena.zip")
        }
        #expect(throws: UpdateVerificationError.checksumMissing) {
            try UpdateVerifier.verifyChecksum(file: f, checksumText: nil, assetName: "Athena.zip")
        }
        #expect(throws: UpdateVerificationError.checksumMalformed) {
            try UpdateVerifier.verifyChecksum(file: f, checksumText: "not a digest", assetName: "Athena.zip")
        }
    }

    @Test func codesignRejectsUnsignedBundle() async throws {
        let app = tempDir().appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await UpdateVerifier.verifyCodeSignature(of: app) }
    }
}

// MARK: - Crash log

@Suite("Crash log")
struct CrashLogTests {
    @Test func reportContainsKeyFacts() {
        let text = CrashLog.report(kind: "exception", detail: "NSRangeException: boom", version: "1.2", date: Date(timeIntervalSince1970: 0), stack: ["frame0"])
        #expect(text.contains("NSRangeException: boom"))
        #expect(text.contains("Version: 1.2"))
        #expect(text.contains("1970-01-01"))
        #expect(text.contains("  frame0"))
    }

    @Test func writesReportFile() throws {
        let dir = tempDir()
        let url = try #require(CrashLog.write("hello", kind: "exception", to: dir.appendingPathComponent("logs")))
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello")
    }
}

// MARK: - Accessibility

@Suite("Accessibility")
struct AccessibilityTests {

    @Test func reduceMotionDisablesAnimation() {
        #expect(AccessibilityPrefs.resolve(.easeInOut, reduceMotion: true) == nil)
        #expect(AccessibilityPrefs.resolve(.easeInOut, reduceMotion: false) != nil)
    }

    @Test func increaseContrastStrengthensBordersAndSelection() {
        #expect(AccessibilityPrefs.borderOpacity(base: 0.1, increaseContrast: true) > 0.1)
        #expect(AccessibilityPrefs.borderOpacity(base: 0.1, increaseContrast: false) == 0.1)
        #expect(AccessibilityPrefs.selectionOpacity(base: 0.1, increaseContrast: true) > 0.1)
    }

    private func luminance(_ c: NSColor) -> Double {
        let s = c.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }
    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test func highContrastThemesClearAAAForTextTokens() {
        for theme in [EditorTheme.athenaHighContrastDark, .athenaHighContrastLight] {
            let tokens: [(String, NSColor)] = [
                ("foreground", theme.foreground), ("keyword", theme.keyword), ("string", theme.string),
                ("number", theme.number), ("comment", theme.comment), ("type", theme.type),
                ("function", theme.function), ("annotation", theme.annotation),
            ]
            for (name, color) in tokens {
                #expect(contrast(color, theme.background) >= 7, "\(theme.id) \(name)")
            }
            #expect(contrast(theme.foreground, theme.selection) >= 4.5, "\(theme.id) selection")
        }
        #expect(EditorTheme.athenaHighContrastDark.isDark)
        #expect(!EditorTheme.athenaHighContrastLight.isDark)
        #expect(EditorTheme.named("athena-hc-dark") == .athenaHighContrastDark)
        #expect(EditorTheme.named("athena-hc-light") == .athenaHighContrastLight)
    }
}
