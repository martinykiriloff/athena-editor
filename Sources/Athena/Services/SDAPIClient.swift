// SDAPIClient.swift
// Athena — HTTPS client for the SFCC Script Debugger API (SDAPI v2.0), see ADR 0002.
// Swift 6, strict concurrency.

import Foundation

// MARK: - Errors

enum SDAPIError: LocalizedError, Equatable {
    case missingCredentials(String)
    case http(status: Int, message: String)
    case invalidResponse(String)
    case notPaused

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let what): return "SFCC debugger: \(what)"
        case .http(let status, let message): return "SFCC debugger HTTP \(status): \(message)"
        case .invalidResponse(let what): return "SFCC debugger: unexpected response for \(what)"
        case .notPaused: return "SFCC debugger: no halted thread"
        }
    }
}

// MARK: - SDAPIClient

/// Thin, endpoint-per-method client. Every call is one HTTPS request against
/// `https://<host>/s/-/dw/debugger/v2_0/`. The transport is injectable so
/// `SFCCDebugSession` can be driven end to end by a fake sandbox in tests.
actor SDAPIClient {

    /// Returns the response body and HTTP status for a request.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    enum StepKind: String, Sendable {
        case into, over, out
    }

    private let baseURL: URL
    private let authorization: String
    private let transport: Transport

    static let clientID = "athena"
    static let requestTimeout: TimeInterval = 10

    /// Throws for a hostname that can't form a URL (stray whitespace from a
    /// pasted value is the usual cause) instead of crashing on a bad URL.
    init(credentials: SFCCDebugCredentials, transport: Transport? = nil) throws {
        guard let url = Self.baseURL(forHostname: credentials.hostname) else {
            throw SDAPIError.missingCredentials("invalid hostname \"\(credentials.hostname)\"")
        }
        baseURL = url
        let raw = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
        authorization = "Basic \(raw)"
        self.transport = transport ?? Self.urlSessionTransport
    }

    /// Accepts "host", "host:port", or a pasted "https://host/" and yields
    /// the SDAPI v2 base URL; nil when the host is empty or contains
    /// whitespace.
    static func baseURL(forHostname raw: String) -> URL? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where host.lowercased().hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: "https://\(host)/s/-/dw/debugger/v2_0/"), url.host != nil else { return nil }
        return url
    }

    private static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: Client lifecycle

    func createClient() async throws {
        _ = try await send("POST", "client")
    }

    func deleteClient() async throws {
        _ = try await send("DELETE", "client")
    }

    // MARK: Breakpoints

    /// Replaces nothing — SDAPI accumulates, so callers clear first if needed.
    @discardableResult
    func setBreakpoints(_ entries: [(scriptPath: String, line: Int)]) async throws -> [SFCCDebugBreakpoint] {
        let body: [String: Any] = [
            "breakpoints": entries.map { ["line_number": $0.line, "script_path": $0.scriptPath] }
        ]
        let data = try await send("POST", "breakpoints", body: try JSONSerialization.data(withJSONObject: body))
        return try Self.parseBreakpoints(data)
    }

    func removeAllBreakpoints() async throws {
        _ = try await send("DELETE", "breakpoints")
    }

    // MARK: Threads

    func threads() async throws -> [SFCCDebugThread] {
        try Self.parseThreads(try await send("GET", "threads"))
    }

    func thread(_ id: Int) async throws -> SFCCDebugThread {
        try Self.parseThread(try await send("GET", "threads/\(id)"))
    }

    /// Resets the halt timeout of every halted thread. The sandbox resumes a
    /// halted thread on its own after roughly a minute; calling this every
    /// 30 s keeps a paused session paused.
    func resetThreads() async throws {
        _ = try await send("POST", "threads/reset")
    }

    func resume(thread id: Int) async throws {
        _ = try await send("POST", "threads/\(id)/resume")
    }

    func step(_ kind: StepKind, thread id: Int) async throws {
        _ = try await send("POST", "threads/\(id)/\(kind.rawValue)")
    }

    func stopThread(_ id: Int) async throws {
        _ = try await send("POST", "threads/\(id)/stop")
    }

    // MARK: Frames

    func variables(thread: Int, frame: Int, start: Int = 0, count: Int = 200) async throws -> [SFCCDebugMember] {
        try Self.parseMembers(try await send(
            "GET", "threads/\(thread)/frames/\(frame)/variables",
            query: ["start": String(start), "count": String(count)]
        ))
    }

    func members(thread: Int, frame: Int, objectPath: String, start: Int = 0, count: Int = 200) async throws -> [SFCCDebugMember] {
        try Self.parseMembers(try await send(
            "GET", "threads/\(thread)/frames/\(frame)/members",
            query: ["object_path": objectPath, "start": String(start), "count": String(count)]
        ))
    }

    func evaluate(thread: Int, frame: Int, expression: String) async throws -> String {
        try Self.parseEvaluate(try await send(
            "GET", "threads/\(thread)/frames/\(frame)/eval",
            query: ["expr": expression]
        ))
    }

    // MARK: - Request plumbing

    private func send(_ method: String, _ path: String,
                      query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.percentEncodedQuery = Self.encodedQuery(query)
        }
        guard let url = components.url else { throw SDAPIError.invalidResponse("url for \(path)") }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(Self.clientID, forHTTPHeaderField: "x-dw-client-id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, status) = try await transport(request)
        guard (200..<300).contains(status) else {
            throw SDAPIError.http(status: status, message: Self.errorMessage(from: data, fallback: "\(method) \(path)"))
        }
        return data
    }

    /// Strict form-encoding. `URLComponents.queryItems` leaves `+` bare,
    /// and the sandbox's servlet decodes a bare `+` as a space — so every
    /// `i + 1` typed into the watch panel or REPL evaluated as `i   1`.
    static func encodedQuery(_ query: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "-._~").union(.alphanumerics)
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        return query.sorted(by: { $0.key < $1.key })
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
    }

    // MARK: - Parsing seams (static, testable without a sandbox)

    private static let decoder = JSONDecoder()

    static func parseThreads(_ data: Data) throws -> [SFCCDebugThread] {
        struct Envelope: Decodable { var script_threads: [SFCCDebugThread]? }
        guard let env = try? decoder.decode(Envelope.self, from: data) else {
            throw SDAPIError.invalidResponse("threads")
        }
        return env.script_threads ?? []
    }

    static func parseThread(_ data: Data) throws -> SFCCDebugThread {
        guard let thread = try? decoder.decode(SFCCDebugThread.self, from: data) else {
            throw SDAPIError.invalidResponse("thread")
        }
        return thread
    }

    static func parseMembers(_ data: Data) throws -> [SFCCDebugMember] {
        struct Envelope: Decodable { var object_members: [SFCCDebugMember]? }
        guard let env = try? decoder.decode(Envelope.self, from: data) else {
            throw SDAPIError.invalidResponse("members")
        }
        return env.object_members ?? []
    }

    static func parseEvaluate(_ data: Data) throws -> String {
        struct Envelope: Decodable { var result: String? }
        guard let env = try? decoder.decode(Envelope.self, from: data) else {
            throw SDAPIError.invalidResponse("eval")
        }
        return env.result ?? ""
    }

    static func parseBreakpoints(_ data: Data) throws -> [SFCCDebugBreakpoint] {
        struct Envelope: Decodable { var breakpoints: [SFCCDebugBreakpoint]? }
        guard let env = try? decoder.decode(Envelope.self, from: data) else {
            throw SDAPIError.invalidResponse("breakpoints")
        }
        return env.breakpoints ?? []
    }

    /// SDAPI error bodies are `{"fault": {"type": ..., "message": ...}}`.
    static func errorMessage(from data: Data, fallback: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let fault = json["fault"] as? [String: Any],
           let message = fault["message"] as? String, !message.isEmpty {
            return message
        }
        return fallback
    }
}
