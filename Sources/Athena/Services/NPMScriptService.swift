// NPMScriptService.swift
// Athena — discovers package.json files and their scripts in a workspace.
// Swift 6, strict concurrency.

import Foundation

// MARK: - PackageInfo

struct NPMPackageInfo: Identifiable, Sendable {
    let id: String          // absolute path to package.json
    let path: URL           // package.json URL
    let name: String        // "name" field from JSON, or directory name
    let scripts: [NPMScript]
    let packageManager: NPMPackageManager
}

struct NPMScript: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let command: String
}

enum NPMPackageManager: String, Sendable {
    case npm, pnpm, yarn
    var command: String { rawValue }
}

// MARK: - NPMScriptService

actor NPMScriptService {

    func discoverPackages(in workspace: URL) async -> [NPMPackageInfo] {
        var packages: [NPMPackageInfo] = []

        // Always check root
        if let pkg = parsePackage(at: workspace.appendingPathComponent("package.json")) {
            packages.append(pkg)
        }

        // Check common monorepo subdirectory names one level deep
        let commonDirs = ["packages", "apps", "libs", "modules"]
        for dir in commonDirs {
            let dirURL = workspace.appendingPathComponent(dir)
            guard let subs = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for sub in subs {
                let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                if let pkg = parsePackage(at: sub.appendingPathComponent("package.json")) {
                    packages.append(pkg)
                }
            }
        }

        return packages
    }

    // MARK: - Private

    private func parsePackage(at url: URL) -> NPMPackageInfo? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawScripts = json["scripts"] as? [String: String],
              !rawScripts.isEmpty
        else { return nil }

        let name = json["name"] as? String ?? url.deletingLastPathComponent().lastPathComponent
        let dir  = url.deletingLastPathComponent()
        let pm   = detectPackageManager(in: dir)
        let scripts = rawScripts
            .sorted { $0.key.localizedCompare($1.key) == .orderedAscending }
            .map { NPMScript(name: $0.key, command: $0.value) }

        return NPMPackageInfo(id: url.path, path: url, name: name, scripts: scripts, packageManager: pm)
    }

    private func detectPackageManager(in dir: URL) -> NPMPackageManager {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("pnpm-lock.yaml").path) { return .pnpm }
        if fm.fileExists(atPath: dir.appendingPathComponent("yarn.lock").path)      { return .yarn  }
        return .npm
    }
}
