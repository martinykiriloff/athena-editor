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

    func buildFileTree(_ url: URL, depth: Int = 0) async throws -> [FileNode] {
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
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            let isDir = values?.isDirectory ?? false
            if isDir && excludedDirectories.contains(name) {
                return false
            }
            return true
        }

        let sorted = filtered.sorted { lhs, rhs in
            let lhsValues = try? lhs.resourceValues(forKeys: [.isDirectoryKey])
            let rhsValues = try? rhs.resourceValues(forKeys: [.isDirectoryKey])
            let lhsIsDir = lhsValues?.isDirectory ?? false
            let rhsIsDir = rhsValues?.isDirectory ?? false

            if lhsIsDir != rhsIsDir {
                return lhsIsDir
            }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }

        var nodes: [FileNode] = []

        for item in sorted {
            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])
            let isDir = resourceValues.isDirectory ?? false

            var node = FileNode(url: item, isDirectory: isDir, depth: depth)

            if isDir && depth < 4 {
                let children = try await buildFileTree(item, depth: depth + 1)
                node.children = children
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
