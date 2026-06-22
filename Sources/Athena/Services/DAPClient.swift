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
    }

    // MARK: - Public API

    var events: AsyncStream<RawMessage> { eventStream }

    // ResponseBody wraps [String: Any] as @unchecked Sendable for cross-actor transfer.
    struct ResponseBody: @unchecked Sendable {
        let json: [String: Any]
        subscript(key: String) -> Any? { json[key] }
    }

    func request(_ command: String, args: [String: Any]? = nil) async throws -> ResponseBody {
        let s = seq; seq += 1
        var msg: [String: Any] = ["seq": s, "type": "request", "command": command]
        if let args { msg["arguments"] = args }
        try send(msg)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ResponseBody, Error>) in
            pendingTyped[s] = cont
        }
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
            if let cont = pendingTyped.removeValue(forKey: reqSeq) {
                let success = msg["success"] as? Bool ?? false
                if success {
                    cont.resume(returning: ResponseBody(json: msg["body"] as? [String: Any] ?? [:]))
                } else {
                    let errMsg = msg["message"] as? String ?? "Unknown error"
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
