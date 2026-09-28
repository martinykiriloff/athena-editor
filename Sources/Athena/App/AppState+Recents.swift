// AppState+Recents.swift
// Athena — recently opened workspaces for the Welcome screen.
// Swift 6, strict concurrency.

import Foundation

extension AppState {

    // MARK: - Recent workspaces

    /// Newline-separated folder paths, newest first. Kept apart from
    /// `athenaRecentPaths` (File ▸ Open Recent), where opened files would
    /// soon push every folder out.
    nonisolated static let recentWorkspacesKey = "athenaRecentWorkspaces"
    nonisolated static let recentWorkspacesLimit = 12

    nonisolated static func recentWorkspacePaths(in defaults: UserDefaults = .standard) -> [String] {
        if let stored = defaults.string(forKey: recentWorkspacesKey) {
            return stored.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        // First run with this list: seed it from the folders already in the
        // shared recent list, so the Welcome screen isn't empty after updating.
        let seeded = (defaults.string(forKey: "athenaRecentPaths") ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
        return Array(seeded.prefix(recentWorkspacesLimit))
    }

    nonisolated static func registerRecentWorkspace(_ url: URL, in defaults: UserDefaults = .standard) {
        var paths = recentWorkspacePaths(in: defaults)
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        defaults.set(paths.prefix(recentWorkspacesLimit).joined(separator: "\n"), forKey: recentWorkspacesKey)
    }

    nonisolated static func removeRecentWorkspace(_ path: String, in defaults: UserDefaults = .standard) {
        let paths = recentWorkspacePaths(in: defaults).filter { $0 != path }
        defaults.set(paths.joined(separator: "\n"), forKey: recentWorkspacesKey)
    }
}
