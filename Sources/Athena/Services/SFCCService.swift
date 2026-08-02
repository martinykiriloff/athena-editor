// SFCCService.swift
// Athena — Salesforce Commerce Cloud WebDAV integration (upload on save + log tailing).
// Swift 6, strict concurrency.

import Foundation

// MARK: - SFCCService

actor SFCCService {

    // MARK: Upload

    /// Uploads `fileURL` to the active SFCC sandbox via WebDAV PUT.
    /// Returns a short status string suitable for the status bar.
    func upload(fileURL: URL, connection: SFCCConnection, workspaceURL: URL) async throws -> String {
        let rel = try Self.cartridgeRelativePath(for: fileURL, connection: connection, workspaceURL: workspaceURL)
        let url = try remoteURL(for: rel, connection: connection)

        let data = try Data(contentsOf: fileURL)
        var req  = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "PUT"
        req.httpBody   = data
        req.addBasicAuth(user: connection.username, password: connection.password)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else { throw SFCCError.httpError(code) }

        return "↑ SFCC \(fileURL.lastPathComponent)"
    }

    /// Removes the sandbox copy of `fileURL` (already deleted locally) via
    /// WebDAV DELETE. A 404 counts as success — the remote file is gone
    /// either way.
    func deleteRemote(fileURL: URL, connection: SFCCConnection, workspaceURL: URL) async throws -> String {
        let rel = try Self.cartridgeRelativePath(for: fileURL, connection: connection, workspaceURL: workspaceURL)
        let url = try remoteURL(for: rel, connection: connection)

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "DELETE"
        req.addBasicAuth(user: connection.username, password: connection.password)

        let (_, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) || code == 404 else { throw SFCCError.httpError(code) }

        return "✕ SFCC \(fileURL.lastPathComponent)"
    }

    // MARK: Log listing

    /// Lists available log file names from the sandbox WebDAV Logs directory.
    func listLogs(connection: SFCCConnection) async throws -> [String] {
        let logsURL = "https://\(connection.hostname)/on/demandware.servlet/webdav/Sites/Logs/"
        guard let url = URL(string: logsURL) else { throw SFCCError.badURL(logsURL) }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "PROPFIND"
        req.addBasicAuth(user: connection.username, password: connection.password)
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <propfind xmlns="DAV:"><prop><displayname/></prop></propfind>
            """.utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        return parseLogNames(from: data)
    }

    // MARK: Log tailing

    /// Fetches new content from `logName` starting at `fromByte`.
    /// Returns the new text and the updated byte offset.
    func fetchLogTail(logName: String, connection: SFCCConnection, fromByte: Int) async throws -> (String, Int) {
        let logURL = "https://\(connection.hostname)/on/demandware.servlet/webdav/Sites/Logs/\(logName)"
        guard let url = URL(string: logURL) else { throw SFCCError.badURL(logURL) }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.addBasicAuth(user: connection.username, password: connection.password)
        if fromByte > 0 {
            req.setValue("bytes=\(fromByte)-", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        if code == 416 { return ("", fromByte) }  // beyond EOF — nothing new

        let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        return (text, fromByte + data.count)
    }

    // MARK: Upload audit log (on disk)

    /// Persistent, append-only record of every upload/delete attempt — one
    /// line per `SFCCUploadRecord`. The in-memory feed on `AppState` dies
    /// with the process; this file is the durable answer to "what exactly
    /// did Athena push to the sandbox, and when".
    nonisolated static var uploadLogFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Athena/logs")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Athena/logs")
        return base.appendingPathComponent("sfcc-uploads.log")
    }

    /// Appends `record` to `uploadLogFileURL`, creating the directory/file on
    /// first use. Failures are swallowed — the audit log must never break an
    /// upload.
    func appendToUploadLogFile(_ record: SFCCUploadRecord) {
        let url = Self.uploadLogFileURL
        let fm  = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }

        let outcome: String
        switch record.status {
        case .success:              outcome = "ok"
        case .failure(let message): outcome = "FAILED — \(message)"
        }
        let line = "\(record.date.formatted(.iso8601)) \(record.kind.rawValue.uppercased()) "
                 + "\(record.relativePath) → \(record.connectionName)/\(record.codeVersion): \(outcome)\n"

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: Path helpers

    /// Resolves the local cartridges root for `connection` — absolute paths
    /// are used as-is, anything else is relative to the workspace root.
    nonisolated static func cartridgesRoot(connection: SFCCConnection, workspaceURL: URL) -> URL {
        connection.cartridgesPath.hasPrefix("/")
            ? URL(fileURLWithPath: connection.cartridgesPath)
            : workspaceURL.appendingPathComponent(connection.cartridgesPath)
    }

    /// The path of `fileURL` relative to the cartridges root — the tail of
    /// its WebDAV destination URL. Throws `.notInCartridge` for files outside
    /// the root (not deployable, callers skip those silently).
    nonisolated static func cartridgeRelativePath(for fileURL: URL,
                                                  connection: SFCCConnection,
                                                  workspaceURL: URL) throws -> String {
        let rootPath = cartridgesRoot(connection: connection, workspaceURL: workspaceURL).standardized.path
        let filePath = fileURL.standardized.path

        guard filePath.hasPrefix(rootPath + "/") else {
            throw SFCCError.notInCartridge(fileURL.path)
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    // MARK: Private helpers

    /// Builds the WebDAV destination URL for a cartridge-relative path,
    /// percent-encoding each component (spaces in content-asset names would
    /// otherwise make `URL(string:)` reject the whole thing).
    private func remoteURL(for relativePath: String, connection: SFCCConnection) throws -> URL {
        let encoded = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        let dest = "https://\(connection.hostname)/on/demandware.servlet/webdav/Sites/Cartridges/\(connection.codeVersion)/\(encoded)"
        guard let url = URL(string: dest) else { throw SFCCError.badURL(dest) }
        return url
    }

    private func parseLogNames(from data: Data) -> [String] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        // Pull out <D:href>…</D:href> values ending in .log
        guard let re = try? NSRegularExpression(pattern: "<[Dd]:\\s*href>([^<]+\\.log)</[Dd]:\\s*href>") else { return [] }
        let ns    = xml as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.matches(in: xml, range: range).compactMap { m -> String? in
            let r = m.range(at: 1)
            guard r.location != NSNotFound else { return nil }
            return ns.substring(with: r).components(separatedBy: "/").last
        }
    }
}

// MARK: - Errors

enum SFCCError: LocalizedError {
    case badURL(String)
    case httpError(Int)
    case notInCartridge(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s):         return "Invalid SFCC URL: \(s)"
        case .httpError(let c):      return "SFCC HTTP \(c)"
        case .notInCartridge(let p): return "File not under cartridges root: \(p)"
        }
    }
}

// MARK: - URLRequest basic-auth helper

private extension URLRequest {
    mutating func addBasicAuth(user: String, password: String) {
        let token = "\(user):\(password)".data(using: .utf8)?.base64EncodedString() ?? ""
        setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }
}
