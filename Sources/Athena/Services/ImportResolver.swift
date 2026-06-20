// ImportResolver.swift
// Athena — resolves import/require path strings to actual file URLs.
// Handles relative paths, bare filenames, directory index files, and
// common source-file extensions.

import Foundation

actor ImportResolver {

    // Extensions tried in order when the import has no extension.
    private static let extensions: [String] = [
        "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "swift", "py", "go", "rs", "rb",
        "css", "scss", "sass", "less",
        "json", "yaml", "yml",
        "vue", "svelte", "astro",
        "md", "mdx",
    ]

    // Index file basenames tried when the resolved path is a directory.
    private static let indexNames: [String] = ["index", "mod", "main"]

    // MARK: - Public

    /// Resolves `importPath` (e.g. `"./configs"` or `"../utils/helper"`) to an
    /// existing file URL, or `nil` when nothing matches.
    func resolve(_ importPath: String, from fileURL: URL, workspaceURL: URL?) async -> URL? {
        // Skip node package / stdlib imports (no leading `.` or `/`).
        guard importPath.hasPrefix(".") || importPath.hasPrefix("/") else { return nil }

        let baseDir = fileURL.deletingLastPathComponent()
        let candidate: URL
        if importPath.hasPrefix("/"), let ws = workspaceURL {
            candidate = ws.appendingPathComponent(importPath).standardized
        } else {
            candidate = baseDir.appendingPathComponent(importPath).standardized
        }

        let fm = FileManager.default

        // 1. Exact path (import already has the extension).
        if fm.fileExists(atPath: candidate.path), !isDir(candidate, fm) {
            return candidate
        }

        // 2. Try appending known extensions.
        for ext in Self.extensions {
            let c = candidate.appendingPathExtension(ext)
            if fm.fileExists(atPath: c.path), !isDir(c, fm) { return c }
        }

        // 3. Treat as a directory and look for index files.
        if isDir(candidate, fm) {
            for name in Self.indexNames {
                for ext in Self.extensions {
                    let c = candidate.appendingPathComponent(name).appendingPathExtension(ext)
                    if fm.fileExists(atPath: c.path) { return c }
                }
            }
        }

        return nil
    }

    // MARK: - Private

    private func isDir(_ url: URL, _ fm: FileManager) -> Bool {
        var flag: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &flag)
        return flag.boolValue
    }
}
