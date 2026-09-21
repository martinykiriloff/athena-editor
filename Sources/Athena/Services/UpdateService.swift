// UpdateService.swift
// Athena — GitHub-release auto-updater.
// Swift 6, strict concurrency.

import Foundation
import AppKit

// MARK: - State machine

/// A published release newer than the running build.
struct UpdateRelease: Sendable, Equatable {
    let version: String
    /// Release notes (GitHub markdown), possibly empty.
    let notes: String
    let downloadURL: URL
    let pageURL: URL?
}

enum UpdateState: Sendable, Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case downloading
    case readyToInstall(appURL: URL)
    case error(String)
}

// MARK: - Service

/// Checks GitHub for a newer release at launch and every few hours after
/// that. When it finds one it asks first (`isPromptPresented` drives
/// `UpdatePromptView`) and never downloads or restarts on its own. The user
/// can install now, be reminded next launch, or skip that version.
@MainActor
@Observable
final class UpdateService {
    private static let skippedVersionKey = "update.skippedVersion"

    var state: UpdateState = .idle
    var lastChecked: Date?
    /// The version string being downloaded / installed, for UI display.
    private(set) var pendingVersion: String?
    /// Drives the "new version available" prompt sheet.
    var isPromptPresented: Bool = false

    /// The running build's version. Nil for a build without an Info.plist
    /// (bare `swift run`), which never checks automatically.
    let currentVersion: String?

    @ObservationIgnored private let fetchLatest: @Sendable () async throws -> UpdateRelease
    @ObservationIgnored private let settings: SettingsService
    @ObservationIgnored private var autoCheckTask: Task<Void, Never>?
    /// "Remind Me Later" silences a version for the rest of this launch only.
    @ObservationIgnored private var remindLaterVersion: String?

    init(
        currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        settings: SettingsService = SettingsService(),
        fetchLatest: @escaping @Sendable () async throws -> UpdateRelease = {
            try await fetchLatestRelease(owner: "martinykiriloff", repo: "athena-editor")
        }
    ) {
        self.currentVersion = currentVersion
        self.settings = settings
        self.fetchLatest = fetchLatest
    }

    var updateAvailable: Bool {
        switch state {
        case .available, .downloading, .readyToInstall: return true
        default: return false
        }
    }

    /// The release on offer, while one is.
    var availableRelease: UpdateRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    // MARK: - Public API

    /// Schedules the background checks: one shortly after launch, then one
    /// every `interval`, owned by this service — not by any SwiftUI view's
    /// `.task`, whose lifetime is tied to that view's identity/presence.
    /// Idempotent — call once at app launch.
    ///
    /// Sleeps via a `ContinuousClock` instance rather than `Task.sleep(for:)`:
    /// the latter is generic over `Clock`, and on non-assertions release
    /// toolchains (Swift 6.2–6.2.3, exactly what ships in a notarized build)
    /// colliding specializations of it across modules corrupt the task
    /// allocator on deallocation, aborting with `swift_task_dealloc`
    /// (see https://github.com/swiftlang/swift/issues/86204).
    func scheduleAutoCheck(after delay: Duration = .seconds(5), every interval: Duration = .seconds(6 * 60 * 60)) {
        guard autoCheckTask == nil, currentVersion != nil else { return }
        autoCheckTask = Task { [weak self] in
            let clock = ContinuousClock()
            var wait = delay
            while !Task.isCancelled {
                try? await clock.sleep(until: clock.now.advanced(by: wait))
                guard !Task.isCancelled else { return }
                await self?.checkForUpdates(userInitiated: false)
                wait = interval
            }
        }
    }

    /// Looks for a newer release and prompts when there is one. A manual
    /// check (menu / Settings) always prompts and reports "up to date"; a
    /// background check stays quiet for a skipped or "later" version and
    /// doesn't surface network errors.
    func checkForUpdates(userInitiated: Bool = true) async {
        switch state {
        case .checking, .downloading, .readyToInstall: return
        default: break
        }
        // An offer already on screen needn't be re-fetched in the background.
        if !userInitiated, isPromptPresented { return }

        let previous = state
        state = .checking
        do {
            let release = try await fetchLatest()
            lastChecked = .now

            guard Self.isNewer(release.version, than: currentVersion ?? "0") else {
                state = userInitiated ? .upToDate : .idle
                return
            }
            state = .available(release)

            let skipped: String = await settings.value(for: Self.skippedVersionKey, default: "")
            let silenced = release.version == skipped || release.version == remindLaterVersion
            if userInitiated || !silenced {
                isPromptPresented = true
            }
        } catch {
            state = userInitiated ? .error(error.localizedDescription) : previous
        }
    }

    /// "Remind Me Later": closes the prompt; the next launch asks again.
    func remindLater() {
        remindLaterVersion = availableRelease?.version
        isPromptPresented = false
    }

    /// "Skip This Version": never prompt for it again in the background
    /// (a manual check still offers it). A newer release prompts as usual.
    func skipAvailableVersion() async {
        guard let version = availableRelease?.version else { return }
        try? await settings.setValue(version, for: Self.skippedVersionKey)
        isPromptPresented = false
        state = .idle
    }

    /// "Install and Restart": downloads the release, runs `prepare` (the
    /// caller saves open files), then replaces the app and relaunches.
    func install(prepare: @MainActor () async -> Void) async {
        guard case .available(let release) = state else { return }
        pendingVersion = release.version
        state = .downloading
        do {
            let appURL = try await downloadAndExtract(from: release.downloadURL)
            state = .readyToInstall(appURL: appURL)
            await prepare()
            installAndRelaunch(newAppURL: appURL)
        } catch {
            state = .error("Download failed: \(error.localizedDescription)")
        }
    }

    func installAndRelaunch(newAppURL: URL) {
        let currentPath = Bundle.main.bundleURL.path
        let newPath     = newAppURL.path
        let scriptURL   = FileManager.default.temporaryDirectory
                            .appendingPathComponent("athena-updater.sh")
        let script = """
        #!/bin/bash
        sleep 2
        rm -rf '\(currentPath)'
        cp -r '\(newPath)' '\(currentPath)'
        open '\(currentPath)'
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
            let proc = Process()
            proc.executableURL  = URL(fileURLWithPath: "/bin/bash")
            proc.arguments      = [scriptURL.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError  = FileHandle.nullDevice
            try proc.run()
            NSApp.terminate(nil)
        } catch {
            state = .error("Updater launch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Version comparison

    /// Numeric, component-wise ("2026.10" > "2026.9"); a leading "v" is ignored.
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").compactMap { Int($0) }
        }
        let l = parts(version)
        let c = parts(current)
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv > cv { return true }
            if lv < cv { return false }
        }
        return false
    }
}

// MARK: - Network helpers (nonisolated, runs off main actor)

private func fetchLatestRelease(owner: String, repo: String) async throws -> UpdateRelease {
    let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    var req = URLRequest(url: url)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    let (data, _) = try await URLSession.shared.data(for: req)
    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    guard
        let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
        let downloadURL = URL(string: asset.browserDownloadURL)
    else {
        throw UpdateError.noArchive(version)
    }
    return UpdateRelease(
        version: version,
        notes: release.body ?? "",
        downloadURL: downloadURL,
        pageURL: release.htmlURL.flatMap(URL.init(string:))
    )
}

private func downloadAndExtract(from downloadURL: URL) async throws -> URL {
    let (tmpFile, _) = try await URLSession.shared.download(from: downloadURL)

    let workDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AthenaUpdate")
    try? FileManager.default.removeItem(at: workDir)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

    let zipURL   = workDir.appendingPathComponent("Athena.zip")
    let unzipDir = workDir.appendingPathComponent("app")
    try FileManager.default.moveItem(at: tmpFile, to: zipURL)
    try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

    try await runProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
        arguments: ["-q", zipURL.path, "-d", unzipDir.path]
    )

    let contents = try FileManager.default.contentsOfDirectory(
        at: unzipDir, includingPropertiesForKeys: nil
    )
    guard let appURL = contents.first(where: { $0.lastPathComponent == "Athena.app" }) else {
        throw UpdateError.appNotFound
    }
    return appURL
}

private func runProcess(executableURL: URL, arguments: [String]) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments     = arguments
        proc.terminationHandler = { p in
            if p.terminationStatus == 0 {
                cont.resume()
            } else {
                cont.resume(throwing: UpdateError.processFailed(p.terminationStatus))
            }
        }
        do {
            try proc.run()
        } catch {
            cont.resume(throwing: error)
        }
    }
}

// MARK: - Errors

private enum UpdateError: LocalizedError {
    case appNotFound
    case processFailed(Int32)
    case noArchive(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound:          return "Athena.app not found in the update archive"
        case .processFailed(let c): return "Process exited with code \(c)"
        case .noArchive(let v):     return "No .zip asset found in release \(v)"
        }
    }
}

// MARK: - GitHub API models

private struct GitHubRelease: Decodable {
    let tagName: String
    let body:    String?
    let htmlURL: String?
    let assets:  [GitHubAsset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name:               String
    let browserDownloadURL: String
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
