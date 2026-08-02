import Foundation

actor FileService {

    // MARK: - Read / Write

    func readFile(_ url: URL) async throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            do {
                return try String(contentsOf: url, encoding: .isoLatin1)
            } catch {
                throw error
            }
        }
    }

    func writeFile(_ url: URL, content: String) async throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - File Tree

    /// `.isDirectoryKey` reports on the item itself, not its target — a
    /// symlink pointing at a directory (common for shared/linked cartridges)
    /// otherwise reads as `false` and never gets recursed into. Resolve the
    /// symlink first so directory-ness reflects what it actually points to.
    private func isDirectory(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        return (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// `ancestorRealPaths` is the resolved (symlink-free) path of `url` itself
    /// plus every directory above it in this traversal — not a global
    /// "already visited" set, so two sibling symlinks pointing at the same
    /// shared cartridge still each get listed. Only recursing into a
    /// directory whose real path is already an ancestor would be an actual
    /// cycle, which is what this guards against now that depth is unbounded.
    func buildFileTree(_ url: URL, depth: Int = 0, ancestorRealPaths: Set<String> = []) async throws -> [FileNode] {
        // Resolve up front: listing a symlink URL directly throws ENOTDIR
        // (see below), and a caller could hand in a symlinked workspace root
        // just as easily as recursion hands in a symlinked subdirectory.
        let url = url.resolvingSymlinksInPath()

        let excludedDirectories: Set<String> = [
            ".git", "node_modules", ".build", "DerivedData",
            "__pycache__", ".swiftpm", "Pods"
        ]

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        )

        let filtered = contents.filter { item in
            let name = item.lastPathComponent
            if isDirectory(item) && excludedDirectories.contains(name) {
                return false
            }
            return true
        }

        let sorted = filtered.sorted { lhs, rhs in
            let lhsIsDir = isDirectory(lhs)
            let rhsIsDir = isDirectory(rhs)

            if lhsIsDir != rhsIsDir {
                return lhsIsDir
            }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }

        var nodes: [FileNode] = []
        var ancestors = ancestorRealPaths
        ancestors.insert(url.resolvingSymlinksInPath().path)

        for item in sorted {
            let isDir = isDirectory(item)

            var node = FileNode(url: item, isDirectory: isDir, depth: depth)

            if isDir {
                let resolved = item.resolvingSymlinksInPath()
                if !ancestors.contains(resolved.path) {
                    // Listing via `item` directly fails with ENOTDIR when it's a
                    // symlink — its URL carries a directory-hint from the
                    // original dirent (a symlink, not a directory), not from
                    // the target. Recurse on the resolved URL instead.
                    //
                    // `try?`, not `try`: one unreadable subtree (permission-
                    // denied, a dangling symlink target, a volume that went
                    // away) must not throw away the entire workspace's file
                    // tree — that single bad directory just shows as empty.
                    node.children = try? await buildFileTree(resolved, depth: depth + 1, ancestorRealPaths: ancestors)
                }
            }

            nodes.append(node)
        }

        return nodes
    }

    // MARK: - Create / Delete / Rename

    func createFile(at url: URL) async throws {
        let created = FileManager.default.createFile(atPath: url.path, contents: nil)
        if !created {
            throw FileServiceError.failedToCreateFile(url)
        }
    }

    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func delete(_ url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    func rename(_ url: URL, to newName: String) async throws -> URL {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: newURL)
        return newURL
    }
}

// MARK: - Errors

enum FileServiceError: Error, LocalizedError {
    case failedToCreateFile(URL)

    var errorDescription: String? {
        switch self {
        case .failedToCreateFile(let url):
            return "Failed to create file at \(url.path)"
        }
    }
}
