// DAPClient.swift
// Athena — Debug Adapter Protocol client.
// Communicates with a debug adapter via stdio using length-prefixed JSON.
// Swift 6, strict concurrency.

import Foundation

// MARK: - DAP errors

enum DAPError: LocalizedError {
    case adapterNotFound(String)
    case launchFailed(String)
    case requestFailed(String)
    case sessionEnded

    var errorDescription: String? {
        switch self {
        case .adapterNotFound(let p): return "Debug adapter not found: \(p)"
        case .launchFailed(let m):    return "Launch failed: \(m)"
        case .requestFailed(let m):   return "DAP request failed: \(m)"
        case .sessionEnded:           return "Debug session ended"
        }
    }
}

// MARK: - DAPClient

actor DAPClient {

    private var process: Process?
    private var inputHandle:  FileHandle?
    private var outputHandle: FileHandle?
    private var seq: Int = 1

    // Pending request completions keyed by sequence number.
    private var pendingTyped: [Int: CheckedContinuation<ResponseBody, Error>] = [:]
    // Buffer for partially received messages.
    private var receiveBuffer = Data()
    /// Requests sent via `beginRequest` that nothing is awaiting yet.
    private var deferredSeqs: Set<Int> = []
    private var deferredResults: [Int: Result<ResponseBody, Error>] = [:]

    // Delivery channel for events (initialized, stopped, continued, output, terminated…)
    // DAPRawMessage wraps [String: Any] as @unchecked Sendable since JSON dicts cross actor boundaries.
    struct RawMessage: @unchecked Sendable { let json: [String: Any] }

    private let eventStream: AsyncStream<RawMessage>
    private let eventContinuation: AsyncStream<RawMessage>.Continuation

    init() {
        var cont: AsyncStream<RawMessage>.Continuation!
        eventStream = AsyncStream { cont = $0 }
        eventContinuation = cont
    }

    // MARK: - Lifecycle

    func start(adapterPath: String, adapterArgs: [String] = [], env: [String: String]? = nil) throws {
        guard FileManager.default.fileExists(atPath: adapterPath) else {
            throw DAPError.adapterNotFound(adapterPath)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: adapterPath)
        p.arguments     = adapterArgs

        if let env {
            var merged = ProcessInfo.processInfo.environment
            env.forEach { merged[$0] = $1 }
            p.environment = merged
        }

        let inPipe  = Pipe()
        let outPipe = Pipe()
        p.standardInput  = inPipe
        p.standardOutput = outPipe
        p.standardError  = Pipe()   // swallow stderr (adapters are chatty)

        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleTermination() }
        }

        try p.run()
        process       = p
        inputHandle   = inPipe.fileHandleForWriting
        outputHandle  = outPipe.fileHandleForReading
        outputHandle?.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            Task { await self?.handleReceivedData(data) }
        }
    }

    func stop() {
        outputHandle?.readabilityHandler = nil
        process?.terminate()
        process = nil
        eventContinuation.finish()
        for (_, cont) in pendingTyped { cont.resume(throwing: DAPError.sessionEnded) }
        pendingTyped.removeAll()
        deferredSeqs.removeAll()
        deferredResults.removeAll()
    }

    // MARK: - Public API

    var events: AsyncStream<RawMessage> { eventStream }

    // ResponseBody wraps [String: Any] as @unchecked Sendable for cross-actor transfer.
    struct ResponseBody: @unchecked Sendable {
        let json: [String: Any]
        subscript(key: String) -> Any? { json[key] }
    }

    /// Sends a DAP request and waits for its response.
    ///
    /// `timeout` exists because an adapter that accepts a request and never
    /// answers would otherwise strand the caller — and the whole debug
    /// session — permanently. The continuation is registered before the
    /// message goes out so a fast adapter can't reply into an empty table.
    func request(
        _ command: String,
        args: [String: Any]? = nil,
        timeout: Duration = .seconds(20)
    ) async throws -> ResponseBody {
        let s = seq; seq += 1
        var msg: [String: Any] = ["seq": s, "type": "request", "command": command]
        if let args { msg["arguments"] = args }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ResponseBody, Error>) in
            pendingTyped[s] = cont
            do {
                try send(msg)
            } catch {
                pendingTyped.removeValue(forKey: s)
                cont.resume(throwing: error)
                return
            }
            Task { [weak self] in
                let clock = ContinuousClock()
                try? await clock.sleep(until: clock.now.advanced(by: timeout))
                await self?.failIfPending(seq: s, command: command)
            }
        }
    }

    /// Fails request `seq` if it is still outstanding — a no-op once the
    /// adapter has answered, which is the normal case.
    private func failIfPending(seq: Int, command: String) {
        guard let cont = pendingTyped.removeValue(forKey: seq) else { return }
        cont.resume(throwing: DAPError.requestFailed("\(command) timed out"))
    }

    /// Sends a request and returns its sequence number without waiting.
    ///
    /// DAP adapters may hold the `launch` response until `configurationDone`
    /// arrives, so a client that awaits `launch` before configuring
    /// deadlocks against any adapter that behaves that way. Pair this with
    /// `awaitResponse(seq:timeout:)` once configuration is finished.
    func beginRequest(_ command: String, args: [String: Any]? = nil) throws -> Int {
        let s = seq; seq += 1
        var msg: [String: Any] = ["seq": s, "type": "request", "command": command]
        if let args { msg["arguments"] = args }
        deferredSeqs.insert(s)
        do {
            try send(msg)
        } catch {
            deferredSeqs.remove(s)
            throw error
        }
        return s
    }

    /// Collects a `beginRequest` response, whether it already arrived or is
    /// still outstanding.
    func awaitResponse(seq s: Int, timeout: Duration = .seconds(20)) async throws -> ResponseBody {
        if let done = deferredResults.removeValue(forKey: s) { return try done.get() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ResponseBody, Error>) in
            deferredSeqs.remove(s)
            pendingTyped[s] = cont
            Task { [weak self] in
                let clock = ContinuousClock()
                try? await clock.sleep(until: clock.now.advanced(by: timeout))
                await self?.failIfPending(seq: s, command: "request \(s)")
            }
        }
    }

    /// Turns a response message into the value or error the caller sees.
    private static func outcome(of msg: [String: Any]) -> Result<ResponseBody, Error> {
        if msg["success"] as? Bool ?? false {
            return .success(ResponseBody(json: msg["body"] as? [String: Any] ?? [:]))
        }
        let body = msg["body"] as? [String: Any]
        let errorObject = body?["error"] as? [String: Any]
        let message = (errorObject?["format"] as? String)
            ?? (msg["message"] as? String)
            ?? "the adapter rejected the request"
        return .failure(DAPError.requestFailed(message))
    }

    // MARK: - Private

    private func send(_ msg: [String: Any]) throws {
        guard let handle = inputHandle else { return }
        let body = try JSONSerialization.data(withJSONObject: msg)
        let header = "Content-Length: \(body.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else { return }
        handle.write(headerData + body)
    }

    private func handleReceivedData(_ data: Data) {
        receiveBuffer.append(data)
        while true {
            // Search for the header/body separator.
            let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let sepRange = receiveBuffer.range(of: sep) else { break }

            let headerBytes = receiveBuffer[receiveBuffer.startIndex..<sepRange.lowerBound]
            guard let headerStr = String(data: headerBytes, encoding: .utf8),
                  let length = parseContentLength(headerStr)
            else { receiveBuffer.removeAll(); break }

            let bodyStart = sepRange.upperBound
            guard let bodyEnd = receiveBuffer.index(bodyStart, offsetBy: length, limitedBy: receiveBuffer.endIndex)
            else { break }   // incomplete body – wait for more data

            let bodyData = receiveBuffer[bodyStart..<bodyEnd]
            receiveBuffer = Data(receiveBuffer[bodyEnd...])

            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                dispatchMessage(json)
            }
        }
    }

    private func parseContentLength(_ header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.components(separatedBy: ":")
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
               let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return n
            }
        }
        return nil
    }

    private func dispatchMessage(_ msg: [String: Any]) {
        let type = msg["type"] as? String ?? ""
        switch type {
        case "response":
            let reqSeq = msg["request_seq"] as? Int ?? 0
            // A deferred request (see `beginRequest`) is usually answered
            // before anything awaits it, so hold the result rather than
            // dropping it on the floor.
            if pendingTyped[reqSeq] == nil, deferredSeqs.contains(reqSeq) {
                deferredSeqs.remove(reqSeq)
                deferredResults[reqSeq] = Self.outcome(of: msg)
                return
            }
            if let cont = pendingTyped.removeValue(forKey: reqSeq) {
                let success = msg["success"] as? Bool ?? false
                if success {
                    cont.resume(returning: ResponseBody(json: msg["body"] as? [String: Any] ?? [:]))
                } else {
                    // DAP puts the useful text in `body.error.format`;
                    // `message` is often just "cancelled" or absent, which
                    // surfaced to the user as "Unknown error".
                    let body = msg["body"] as? [String: Any]
                    let errorObject = body?["error"] as? [String: Any]
                    let errMsg = (errorObject?["format"] as? String)
                        ?? (msg["message"] as? String)
                        ?? "the adapter rejected the request"
                    cont.resume(throwing: DAPError.requestFailed(errMsg))
                }
            }
        case "event":
            eventContinuation.yield(RawMessage(json: msg))
        default:
            break
        }
    }

    private func handleTermination() {
        eventContinuation.yield(RawMessage(json: ["type": "event", "event": "terminated", "body": [:]]))
        eventContinuation.finish()
        for (_, cont) in pendingTyped { cont.resume(throwing: DAPError.sessionEnded) }
        pendingTyped.removeAll()
    }
}
