// HTTPClientService.swift
// Athena — sends .http-file requests with URLSession and summarises the response.
// Swift 6, strict concurrency.

import Foundation

enum HTTPClientError: LocalizedError {
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "Not a valid URL: \(u)"
        }
    }
}

actor HTTPClientService {

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Send

    func send(_ spec: HTTPRequestSpec) async throws -> HTTPResponseResult {
        let request = try Self.makeRequest(spec)
        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session.data(for: request)
        let elapsed = start.duration(to: clock.now)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return Self.summarise(spec: spec, response: http, data: data, elapsed: elapsed)
    }

    // MARK: - Pure helpers

    static func makeRequest(_ spec: HTTPRequestSpec) throws -> URLRequest {
        guard let url = URL(string: spec.url), url.scheme != nil, url.host != nil else {
            throw HTTPClientError.invalidURL(spec.url)
        }
        var request = URLRequest(url: url)
        request.httpMethod = spec.method
        for h in spec.headers { request.addValue(h.value, forHTTPHeaderField: h.name) }
        if let body = spec.body { request.httpBody = Data(body.utf8) }
        return request
    }

    static func summarise(spec: HTTPRequestSpec, response: HTTPURLResponse, data: Data, elapsed: Duration) -> HTTPResponseResult {
        let headers = response.allHeaderFields.compactMap { k, v -> HTTPHeader? in
            guard let k = k as? String else { return nil }
            return HTTPHeader(name: k, value: "\(v)")
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let contentType = headers.first { $0.name.lowercased() == "content-type" }?.value
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes of binary data>"
        let looksJSON = (contentType?.lowercased().contains("json") ?? false) || text.first == "{" || text.first == "["
        let pretty = looksJSON ? JSONPrettyPrinter.format(text) : nil
        let comps = elapsed.components
        let ms = Double(comps.seconds) * 1000 + Double(comps.attoseconds) / 1e15
        return HTTPResponseResult(
            requestMethod: spec.method, requestURL: spec.url,
            statusCode: response.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized,
            headers: headers, bodyText: text, prettyBody: pretty ?? text,
            isJSON: pretty != nil, byteCount: data.count, durationMs: ms, contentType: contentType)
    }

    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
