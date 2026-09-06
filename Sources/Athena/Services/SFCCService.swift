// SFCCService.swift
// Athena — Salesforce Commerce Cloud WebDAV integration (upload on save + log tailing).
// Swift 6, strict concurrency.

import Foundation

// MARK: - SFCCService

actor SFCCService {

    /// Returns the response body and HTTP status for a request. Injectable
    /// so the whole WebDAV protocol — PUT, MKCOL retry, the zip/UNZIP
    /// cartridge sequence — can be exercised against a fake sandbox in
    /// tests, the same way `SDAPIClient` is (ADR 0002).
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    private let transport: Transport

    init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }


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

        var code = try await send(req)
        // WebDAV rejects a PUT whose parent collection doesn't exist with
        // 409. That is the normal case for the first file in a new folder,
        // so create the ancestors and retry rather than reporting a failure
        // the user can do nothing about.
        if code == 409 {
            try await createParentCollections(for: rel, connection: connection)
            code = try await send(req)
        }
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

        let code = try await send(req)
        guard (200...299).contains(code) || code == 404 else { throw SFCCError.httpError(code) }

        return "✕ SFCC \(fileURL.lastPathComponent)"
    }

    // MARK: Full cartridge upload

    /// Replaces one cartridge on the sandbox wholesale, following the same
    /// sequence Prophet uses: upload a zip and let the server expand it.
    ///
    /// A cartridge is thousands of small files; uploading them one PUT at a
    /// time takes minutes and leaves the sandbox in a half-updated state if
    /// it fails partway. One zip plus a server-side UNZIP is a handful of
    /// requests and lands atomically enough to be safe to retry.
    ///
    /// The remote directory is deleted first so files removed locally don't
    /// linger on the sandbox — the reason "re-upload everything" exists at
    /// all is usually that the two have drifted apart.
    func uploadCartridge(
        name: String,
        localDirectory: URL,
        connection: SFCCConnection
    ) async throws {
        let archiveName = "\(name)_cartridge.zip"
        let archiveURL  = try remoteURL(for: archiveName, connection: connection)

        // A zip left behind by an interrupted run would be expanded again.
        _ = try? await sendExpecting(request(archiveURL, method: "DELETE", connection: connection))

        let localZip = try Self.makeZip(of: localDirectory, named: name)
        defer { try? FileManager.default.removeItem(at: localZip.deletingLastPathComponent()) }

        var put = request(archiveURL, method: "PUT", connection: connection)
        put.httpBody = try Data(contentsOf: localZip)
        put.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        try await sendExpecting(put)

        let directoryURL = try remoteURL(for: name, connection: connection)
        _ = try? await sendExpecting(request(directoryURL, method: "DELETE", connection: connection))

        var unzip = request(archiveURL, method: "POST", connection: connection)
        unzip.httpBody = Data("method=UNZIP".utf8)
        unzip.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        try await sendExpecting(unzip)

        _ = try? await sendExpecting(request(archiveURL, method: "DELETE", connection: connection))
    }

    /// Zips `directory` so the archive's single root entry is the cartridge
    /// folder itself — the server expands it in place, so the nesting has to
    /// match what the sandbox expects.
    ///
    /// Shells out to `/usr/bin/zip` rather than adding an archiving
    /// dependency, matching how every other external tool here is used.
    nonisolated static func makeZip(of directory: URL, named name: String) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("athena-sfcc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let archive = staging.appendingPathComponent("\(name).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -r recurse, -q quiet, -X drop extra attributes the sandbox ignores.
        process.arguments = ["-r", "-q", "-X", archive.path, directory.lastPathComponent,
                             "-x", ".DS_Store", "-x", "*/.git/*", "-x", "*/node_modules/*"]
        process.currentDirectoryURL = directory.deletingLastPathComponent()
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: archive.path) else {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SFCCError.zipFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return archive
    }

    // MARK: Request plumbing

    private func request(_ url: URL, method: String, connection: SFCCConnection) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method
        req.addBasicAuth(user: connection.username, password: connection.password)
        return req
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Int {
        try await transport(request).1
    }

    /// Sends `request` and throws unless the sandbox accepted it.
    @discardableResult
    private func sendExpecting(_ request: URLRequest) async throws -> Int {
        let code = try await send(request)
        guard (200...299).contains(code) else { throw SFCCError.httpError(code) }
        return code
    }

    /// MKCOLs every missing ancestor collection of `relativePath`.
    /// 405 means it already exists, which is the common case and not an error.
    private func createParentCollections(for relativePath: String, connection: SFCCConnection) async throws {
        let components = relativePath.components(separatedBy: "/").dropLast()
        var walked: [String] = []
        for component in components where !component.isEmpty {
            walked.append(component)
            let url = try remoteURL(for: walked.joined(separator: "/"), connection: connection)
            let code = try await send(request(url, method: "MKCOL", connection: connection))
            guard (200...299).contains(code) || code == 405 || code == 301 else {
                throw SFCCError.httpError(code)
            }
        }
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

        let (data, _) = try await transport(req)
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

        let (data, code) = try await transport(req)
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

    /// Finds cartridges below `root`: directories that contain a `cartridge`
    /// subdirectory, keyed by cartridge name. Bounded depth and the usual
    /// dependency/build folders skipped, so a whole monorepo is cheap to
    /// scan. Feeds `SFCCCartridgeMap` for Script Path translation.
    nonisolated static func discoverCartridges(under root: URL, maxDepth: Int = 6) -> [String: URL] {
        let skipped: Set<String> = [
            "node_modules", ".git", ".build", "DerivedData", "dist", "build", "coverage", ".svn"
        ]
        var result: [String: URL] = [:]
        var visited: Set<String> = []
        let fm = FileManager.default

        // Symlinked cartridges are common (shared/linked cartridges), and
        // `.isDirectoryKey` describes the link, not its target — resolve
        // first, the same trap `FileService.buildFileTree` documents. Stored
        // URLs are resolved too, so they compare equal to the tab URLs the
        // file tree produces (which also lists the resolved root).
        func scan(_ dir: URL, depth: Int) {
            guard depth <= maxDepth, visited.insert(dir.path).inserted,
                  let items = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                  ) else { return }
            for item in items {
                let resolved = item.resolvingSymlinksInPath()
                guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let name = item.lastPathComponent
                if skipped.contains(name) { continue }
                if name == "cartridge" {
                    let cartridgeName = dir.lastPathComponent
                    if result[cartridgeName] == nil { result[cartridgeName] = dir }
                    continue
                }
                scan(resolved, depth: depth + 1)
            }
        }
        scan(root.resolvingSymlinksInPath(), depth: 0)
        return result
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

extension SFCCError {
    /// A bare status code tells the user nothing they can act on. These are
    /// the answers a sandbox actually gives, and what each one means.
    static func explain(_ code: Int) -> String {
        switch code {
        case 401:
            return "HTTP 401 — the sandbox rejected these credentials. Check the username and password, and that the account has WebDAV access."
        case 403:
            return "HTTP 403 — no permission for this code version. Check WebDAV file permissions for the account, and that the code version isn't locked."
        case 404:
            return "HTTP 404 — no such code version on this sandbox."
        case 405:
            return "HTTP 405 — the sandbox refused the method at this path."
        case 507:
            return "HTTP 507 — the sandbox is out of storage."
        case 521, 522, 523, 524:
            return "HTTP \(code) — the sandbox isn't answering. An on-demand sandbox that has hibernated has to be started before it accepts uploads."
        case 502, 503:
            return "HTTP \(code) — the sandbox is unavailable or restarting."
        default:
            return "HTTP \(code)"
        }
    }
}

enum SFCCError: LocalizedError {
    case badURL(String)
    case httpError(Int)
    case notInCartridge(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s):         return "Invalid SFCC URL: \(s)"
        case .httpError(let code):   return Self.explain(code)
        case .notInCartridge(let p): return "File not under cartridges root: \(p)"
        case .zipFailed(let m):      return "Couldn't archive cartridge: \(m.isEmpty ? "zip failed" : m)"
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
