// UpdateService.swift
// Athena — GitHub-release auto-updater.
// Swift 6, strict concurrency.

import Foundation
import AppKit

// MARK: - State machine

enum UpdateState: Sendable {
    case idle
    case checking
    case upToDate
    case available(version: String, downloadURL: URL)
    case downloading
    case readyToInstall(appURL: URL)
    case error(String)
}

// MARK: - Service

@MainActor
@Observable
final class UpdateService {
    private let repoOwner = "martinykiriloff"
    private let repoName  = "athena-editor"

    var state: UpdateState = .idle
    var lastChecked: Date?

    var updateAvailable: Bool {
        switch state {
        case .available, .readyToInstall: return true
        default: return false
        }
    }

    // MARK: - Public API

    func checkForUpdates() async {
        state = .checking
        do {
            let release = try await fetchLatestRelease(owner: repoOwner, repo: repoName)
            lastChecked = .now
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let latest  = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))

            if isNewer(latest, than: current) {
                guard
                    let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
                    let url   = URL(string: asset.browserDownloadURL)
                else {
                    state = .error("No .zip asset found in release \(latest)")
                    return
                }
                state = .available(version: latest, downloadURL: url)
            } else {
                state = .upToDate
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func downloadAndInstall(from url: URL) async {
        state = .downloading
        do {
            let appURL = try await downloadAndExtract(from: url)
            state = .readyToInstall(appURL: appURL)
        } catch {
            state = .error(error.localizedDescription)
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

    // MARK: - Semver comparison

    private func isNewer(_ version: String, than current: String) -> Bool {
        let l = version.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap  { Int($0) }
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

private func fetchLatestRelease(owner: String, repo: String) async throws -> GitHubRelease {
    let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    var req = URLRequest(url: url)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONDecoder().decode(GitHubRelease.self, from: data)
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

    var errorDescription: String? {
        switch self {
        case .appNotFound:          return "Athena.app not found in the update archive"
        case .processFailed(let c): return "Process exited with code \(c)"
        }
    }
}

// MARK: - GitHub API models

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets:  [GitHubAsset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
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
