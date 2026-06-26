// CDPClient.swift
// Athena — Chrome DevTools Protocol client over WebSocket.
// Works for Node.js (--inspect-brk) and Chromium-family browsers (remote-debugging-port).
// Swift 6, strict concurrency.

import Foundation

// MARK: - CDPError

enum CDPError: LocalizedError {
    case noTarget(port: Int)
    case noBrowser
    case disconnected
    case encodingFailed
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .noTarget(let p): return "No debug target on port \(p). Is the process running with --inspect?"
        case .noBrowser:       return "No browser found (install Chrome, Chromium, Edge, or Brave)."
        case .disconnected:    return "Debugger disconnected."
        case .encodingFailed:  return "Failed to encode CDP message."
        case .rpcError(let m): return "CDP: \(m)"
        }
    }
}

// MARK: - CDPClient

actor CDPClient {

    // @unchecked Sendable wrapper so [String: Any] can cross actor boundaries.
    struct Msg: @unchecked Sendable { let json: [String: Any] }

    // Return value from send() — same @unchecked Sendable pattern as DAPClient.ResponseBody.
    struct Response: @unchecked Sendable {
        let json: [String: Any]
        subscript(key: String) -> Any? { json[key] }
    }

    private var wsTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var pending: [Int: CheckedContinuation<Response, Error>] = [:]
    private var mid: Int = 1

    private let eventStream: AsyncStream<Msg>
    private let evtCont:     AsyncStream<Msg>.Continuation

    init() {
        var cont: AsyncStream<Msg>.Continuation!
        eventStream = AsyncStream { cont = $0 }
        evtCont = cont
    }

    var events: AsyncStream<Msg> { eventStream }

    // MARK: - Connection

    func connect(to wsURL: URL) {
        let t = session.webSocketTask(with: wsURL)
        wsTask = t
        t.resume()
        startReceiving()
    }

    func disconnect() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        evtCont.finish()
        for (_, c) in pending { c.resume(throwing: CDPError.disconnected) }
        pending.removeAll()
    }

    // MARK: - Messaging

    // No-params overload — avoids materialising [String: Any] on the caller's actor.
    func send(_ method: String) async throws -> Response {
        try await buildAndSend(method, params: [:])
    }

    // Params are pre-encoded to Data (Sendable) by the caller so [String: Any]
    // never crosses the actor boundary.
    func send(_ method: String, paramsJSON: Data) async throws -> Response {
        guard let params = try? JSONSerialization.jsonObject(with: paramsJSON) as? [String: Any]
        else { throw CDPError.encodingFailed }
        return try await buildAndSend(method, params: params)
    }

    // Stays inside the actor — [String: Any] is fine here.
    private func buildAndSend(_ method: String, params: [String: Any]) async throws -> Response {
        let id = mid; mid += 1
        var payload: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { payload["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let str = String(data: data, encoding: .utf8) else { throw CDPError.encodingFailed }
        try await wsTask?.send(.string(str))
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }

    nonisolated private func startReceiving() {
        Task { [weak self] in await self?.receiveLoop() }
    }

    private func receiveLoop() async {
        while wsTask != nil {
            guard let t = wsTask else { break }
            do {
                let msg = try await t.receive()
                dispatch(msg)
            } catch {
                evtCont.yield(Msg(json: ["method": "_disconnect"]))
                evtCont.finish()
                break
            }
        }
    }

    private func dispatch(_ msg: URLSessionWebSocketTask.Message) {
        let data: Data
        switch msg {
        case .string(let s): data = Data(s.utf8)
        case .data(let d):   data = d
        @unknown default:    return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = json["id"] as? Int {
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let result = json["result"] as? [String: Any] {
                cont.resume(returning: Response(json: result))
            } else {
                let errMsg = (json["error"] as? [String: Any])?["message"] as? String ?? "CDP error"
                cont.resume(throwing: CDPError.rpcError(errMsg))
            }
        } else if json["method"] != nil {
            evtCont.yield(Msg(json: json))
        }
    }

    // MARK: - Target Discovery

    /// Polls `http://127.0.0.1:PORT/json/list` until a matching target appears (up to 10 s).
    static func targetWebSocketURL(port: Int, pageURLContains filter: String? = nil) async throws -> URL {
        guard let listURL = URL(string: "http://127.0.0.1:\(port)/json/list") else {
            throw CDPError.noTarget(port: port)
        }
        for _ in 1...20 {
            if let (data, _) = try? await URLSession.shared.data(from: listURL),
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let target: [String: Any]?
                if let filter {
                    target = targets.first { ($0["url"] as? String ?? "").contains(filter) }
                           ?? targets.first { ($0["type"] as? String) == "page" }
                } else {
                    target = targets.first
                }
                if let t = target,
                   let wsStr = t["webSocketDebuggerUrl"] as? String,
                   let wsURL = URL(string: wsStr) { return wsURL }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw CDPError.noTarget(port: port)
    }

    // MARK: - Browser Discovery

    static func findChrome() throws -> String {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) { return path }
        throw CDPError.noBrowser
    }
}
