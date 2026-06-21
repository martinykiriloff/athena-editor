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
        let rel  = try relativePath(for: fileURL, connection: connection, workspaceURL: workspaceURL)
        let dest = "https://\(connection.hostname)/on/demandware.servlet/webdav/Sites/Cartridges/\(connection.codeVersion)/\(rel)"
        guard let url = URL(string: dest) else { throw SFCCError.badURL(dest) }

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

    // MARK: Private helpers

    private func relativePath(for fileURL: URL,
                              connection: SFCCConnection,
                              workspaceURL: URL) throws -> String {
        let cartRoot: URL = connection.cartridgesPath.hasPrefix("/")
            ? URL(fileURLWithPath: connection.cartridgesPath)
            : workspaceURL.appendingPathComponent(connection.cartridgesPath)

        let rootPath = cartRoot.standardized.path
        let filePath = fileURL.standardized.path

        guard filePath.hasPrefix(rootPath) else {
            throw SFCCError.notInCartridge(fileURL.path)
        }
        // Drop the root prefix and any leading slash
        var rel = String(filePath.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        return rel
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
