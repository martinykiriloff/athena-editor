// UpdateServiceTests.swift
// Athena — when the updater prompts, stays quiet, and remembers a skipped version.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

// MARK: - Helpers

private struct Offline: Error {}

private func release(_ version: String) -> UpdateRelease {
    UpdateRelease(
        version: version,
        notes: "- Faster things",
        downloadURL: URL(string: "https://example.com/Athena.zip")!,
        pageURL: nil
    )
}

private func makeSettings() throws -> (SettingsService, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("athena-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (SettingsService(directory: dir), dir)
}

// MARK: - Tests

@Suite("Update prompt")
@MainActor
struct UpdateServiceTests {
    @Test func versionComparisonIsNumeric() {
        #expect(UpdateService.isNewer("2026.10", than: "2026.9"))
        #expect(UpdateService.isNewer("v2026.6", than: "2026.5"))
        #expect(UpdateService.isNewer("2026.5.1", than: "2026.5"))
        #expect(!UpdateService.isNewer("2026.5", than: "2026.5"))
        #expect(!UpdateService.isNewer("2026.4", than: "2026.5"))
    }

    @Test func newerReleasePromptsWithoutDownloading() async throws {
        let (settings, dir) = try makeSettings()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = UpdateService(currentVersion: "2026.5", settings: settings) { release("2026.6") }

        await service.checkForUpdates(userInitiated: false)
        #expect(service.state == .available(release("2026.6")))
        #expect(service.isPromptPresented)
        #expect(service.pendingVersion == nil)
    }

    @Test func sameVersionStaysQuiet() async throws {
        let (settings, dir) = try makeSettings()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = UpdateService(currentVersion: "2026.5", settings: settings) { release("2026.5") }

        await service.checkForUpdates(userInitiated: false)
        #expect(service.state == .idle)
        #expect(!service.isPromptPresented)

        await service.checkForUpdates(userInitiated: true)
        #expect(service.state == .upToDate)
    }

    @Test func skippedVersionIsRememberedButNewerOnesStillPrompt() async throws {
        let (settings, dir) = try makeSettings()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = UpdateService(currentVersion: "2026.5", settings: settings) { release("2026.6") }
        await first.checkForUpdates(userInitiated: false)
        await first.skipAvailableVersion()
        #expect(!first.isPromptPresented)

        // A later launch doesn't nag about the skipped version…
        let relaunch = UpdateService(currentVersion: "2026.5", settings: settings) { release("2026.6") }
        await relaunch.checkForUpdates(userInitiated: false)
        #expect(!relaunch.isPromptPresented)
        #expect(relaunch.updateAvailable)

        // …but a manual check still offers it,
        await relaunch.checkForUpdates(userInitiated: true)
        #expect(relaunch.isPromptPresented)

        // and a newer release prompts again.
        let newer = UpdateService(currentVersion: "2026.5", settings: settings) { release("2026.7") }
        await newer.checkForUpdates(userInitiated: false)
        #expect(newer.isPromptPresented)
    }

    @Test func remindLaterSilencesOnlyThisLaunch() async throws {
        let (settings, dir) = try makeSettings()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = UpdateService(currentVersion: "2026.5", settings: settings) { release("2026.6") }
        await service.checkForUpdates(userInitiated: false)
        service.remindLater()
        #expect(!service.isPromptPresented)

        await service.checkForUpdates(userInitiated: false)
        #expect(!service.isPromptPresented)

        let relaunch = UpdateService(currentVersion: "2026.5", settings: settings) { release("2026.6") }
        await relaunch.checkForUpdates(userInitiated: false)
        #expect(relaunch.isPromptPresented)
    }

    @Test func backgroundNetworkErrorsAreSilent() async throws {
        let (settings, dir) = try makeSettings()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = UpdateService(currentVersion: "2026.5", settings: settings) { throw Offline() }

        await service.checkForUpdates(userInitiated: false)
        #expect(service.state == .idle)

        await service.checkForUpdates(userInitiated: true)
        if case .error = service.state {} else { Issue.record("manual check should report the error") }
    }
}
