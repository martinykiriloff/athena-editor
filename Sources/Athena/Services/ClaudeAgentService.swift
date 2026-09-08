// ClaudeAgentService.swift
// Athena — a long-lived `claude` CLI agent session over the stream-json protocol.
// Swift 6, strict concurrency.

import Foundation

// MARK: - Configuration

/// Everything needed to launch one agent session.
struct ClaudeAgentConfig: Sendable {
    var account: ClaudeAccount = .personal
    var workingDirectory: URL?
    /// Extra roots the agent may touch (`--add-dir`).
    var additionalDirectories: [URL] = []
    var model: ClaudeModelOption = .auto
    var permissionMode: ClaudePermissionMode = .normal
    /// Resume an earlier conversation instead of starting fresh.
    var resumeSessionId: String?
}

// MARK: - Errors

enum ClaudeAgentError: Error, Sendable {
    case binaryNotFound(String)
    case launchFailed(String)
    case notRunning
}

// MARK: - ClaudeAgentService

/// Owns one `claude --print --input-format stream-json` child process for the
/// lifetime of a conversation.
///
/// Unlike a one-shot `--print` invocation, the process stays alive across
/// turns, so the CLI keeps its own conversation state, its tool loop, its
/// session id and its permission bookkeeping — which is what makes tool-call
/// streaming, mid-turn permission prompts and interrupts possible at all.
actor ClaudeAgentService {

    // MARK: State

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var decoder = ClaudeStreamDecoder()
    private var continuation: AsyncStream<ClaudeAgentEvent>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var stderrBuffer = ""
    private var controlRequestCounter = 0
    /// Bumped on every `start`. The pump task carries the generation it was
    /// created for: cancelling a task does not stop its `AsyncStream` from
    /// draining, so without this a torn-down session's pump could finish and
    /// clear the state of the session that replaced it.
    private var generation = 0

    /// True between a successful `start(...)` and the process exiting.
    private(set) var isRunning = false

    // MARK: - Lifecycle

    /// Launches the agent and returns the event stream for its whole lifetime.
    /// The stream finishes when the process exits or `stop()` is called.
    func start(config: ClaudeAgentConfig) throws -> AsyncStream<ClaudeAgentEvent> {
        stop()

        let extraPaths = Self.searchPaths
        guard let binary = Self.resolveBinary(config.account.binaryName, extraPaths: extraPaths) else {
            throw ClaudeAgentError.binaryNotFound(config.account.binaryName)
        }

        let process = Process()
        let inPipe  = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL  = URL(fileURLWithPath: binary)
        process.arguments      = Self.arguments(for: config)
        process.standardInput  = inPipe
        process.standardOutput = outPipe
        process.standardError  = errPipe
        process.environment    = Self.environment(for: config, extraPaths: extraPaths)
        if let cwd = config.workingDirectory {
            process.currentDirectoryURL = cwd
        }

        // Raw stdout lines are handed to a consumer task rather than decoded
        // in the readability handler: the decoder is actor state, and the
        // handler fires on an arbitrary Dispatch thread.
        let (lines, lineContinuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        let splitter = LineSplitter { lineContinuation.yield($0) }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                splitter.flush()
                lineContinuation.finish()
                handle.readabilityHandler = nil
                return
            }
            splitter.consume(data)
        }

        let stderrSink = ErrorSink()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) { stderrSink.append(text) }
        }

        let (events, eventContinuation) = AsyncStream<ClaudeAgentEvent>.makeStream(bufferingPolicy: .unbounded)

        do {
            try process.run()
        } catch {
            lineContinuation.finish()
            eventContinuation.finish()
            throw ClaudeAgentError.launchFailed(error.localizedDescription)
        }

        generation += 1
        let generation = self.generation

        self.process      = process
        self.stdinHandle  = inPipe.fileHandleForWriting
        self.continuation = eventContinuation
        self.decoder      = ClaudeStreamDecoder()
        self.stderrBuffer = ""
        self.isRunning    = true

        // Terminating the child closes stdout, which finishes `lines`, which
        // ends the pump task below — so exit is observed through one path.
        process.terminationHandler = { _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            splitter.flush()
            lineContinuation.finish()
        }

        pumpTask = Task { [weak self] in
            for await line in lines {
                await self?.handle(line: line, generation: generation)
            }
            await self?.finish(stderr: stderrSink.text, generation: generation)
        }

        // The SDK handshake: the CLI answers with the live command catalogue
        // (skills, plugins, project commands) for this machine.
        sendControlRequest(subtype: "initialize", fields: [:], requestId: "initialize")

        return events
    }

    /// Terminates the child process and finishes the event stream.
    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        if let process, process.isRunning {
            process.terminate()
        }
        try? stdinHandle?.close()
        process       = nil
        stdinHandle   = nil
        isRunning     = false
        continuation?.finish()
        continuation  = nil
    }

    // MARK: - Sending

    /// Queues a user turn. The CLI accepts input at any time; a message sent
    /// mid-turn is picked up once the current turn ends.
    func send(text: String) {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        write(message)
    }

    /// Answers a `can_use_tool` control request.
    func respond(to request: ClaudePermissionRequest, decision: ClaudePermissionDecision) {
        var payload: [String: Any]

        switch decision {
        case .allowOnce:
            payload = ["behavior": "allow", "updatedInput": request.input.foundationObject]

        case .allowAlways(let suggestion):
            payload = [
                "behavior": "allow",
                "updatedInput": request.input.foundationObject,
                "updatedPermissions": [suggestion.raw.foundationObject],
            ]

        case .deny(let message):
            payload = [
                "behavior": "deny",
                "message": message ?? "The user declined this tool call.",
                "interrupt": false,
            ]
        }

        write([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": request.id,
                "response": payload,
            ],
        ])
    }

    /// Interrupts the running turn — the CLI's Escape.
    func interrupt() {
        sendControlRequest(subtype: "interrupt", fields: [:])
    }

    /// Switches models without restarting the conversation.
    func setModel(_ model: ClaudeModelOption) {
        sendControlRequest(subtype: "set_model", fields: ["model": model.alias as Any? ?? NSNull()])
    }

    /// Switches permission mode without restarting the conversation.
    func setPermissionMode(_ mode: ClaudePermissionMode) {
        sendControlRequest(subtype: "set_permission_mode", fields: ["mode": mode.cliValue])
    }

    // MARK: - Private: stream handling

    private func handle(line: String, generation: Int) {
        guard generation == self.generation else { return }
        let events = decoder.decode(line: line)
        guard !events.isEmpty else { return }
        for event in events { continuation?.yield(event) }
    }

    /// Called once the child's stdout closes. Surfaces stderr only when the
    /// exit looks abnormal, so a clean shutdown stays silent.
    private func finish(stderr: String, generation: Int) {
        guard generation == self.generation else { return }
        let status = process?.terminationStatus ?? 0
        isRunning = false

        if status != 0 {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = trimmed.isEmpty
                ? "The Claude agent exited unexpectedly (status \(status))."
                : trimmed
            continuation?.yield(.notice(text: text, level: .error))
        }

        continuation?.finish()
        continuation = nil
        process      = nil
        try? stdinHandle?.close()
        stdinHandle  = nil
    }

    // MARK: - Private: writing

    private func sendControlRequest(subtype: String, fields: [String: Any], requestId: String? = nil) {
        controlRequestCounter += 1
        var request: [String: Any] = ["subtype": subtype]
        for (key, value) in fields { request[key] = value }

        write([
            "type": "control_request",
            "request_id": requestId ?? "athena-\(controlRequestCounter)",
            "request": request,
        ])
    }

    private func write(_ object: [String: Any]) {
        guard let handle = stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        data.append(0x0A)   // newline-delimited JSON

        // SIGPIPE is ignored process-wide (AthenaApp.init), so a write to a
        // dead child surfaces as a thrown EPIPE rather than killing the app.
        do {
            try handle.write(contentsOf: data)
        } catch {
            isRunning = false
            continuation?.yield(.notice(text: "Lost connection to the Claude agent.", level: .error))
        }
    }

    // MARK: - Private: launch details

    /// Common install locations — apps launched from Finder inherit a stripped
    /// PATH that omits every one of them.
    private static let searchPaths: [String] = [
        "\(NSHomeDirectory())/.local/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "\(NSHomeDirectory())/.npm-global/bin",
        "\(NSHomeDirectory())/.bun/bin",
    ]

    static func resolveBinary(_ name: String, extraPaths: [String]) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let fm = FileManager.default
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        for dir in extraPaths + pathDirs where !dir.isEmpty {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func arguments(for config: ClaudeAgentConfig) -> [String] {
        var args = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            // Route permission prompts to us rather than auto-denying them.
            "--permission-prompts", "host",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", config.permissionMode.cliValue,
        ]

        if let alias = config.model.alias {
            args += ["--model", alias]
        }
        if let resume = config.resumeSessionId, !resume.isEmpty {
            args += ["--resume", resume]
        }
        let extraDirs = config.additionalDirectories.map(\.path)
        if !extraDirs.isEmpty {
            args += ["--add-dir"] + extraDirs
        }
        return args
    }

    static func environment(for config: ClaudeAgentConfig, extraPaths: [String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let basePath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [basePath]).joined(separator: ":")

        // The "work" account is just a second CLI config root — the same
        // mechanism the `claude-work` shell function uses.
        if let configDir = config.account.configDirectory {
            env["CLAUDE_CONFIG_DIR"] = configDir
        }
        // Identify Athena in the CLI's telemetry/user-agent surface.
        env["CLAUDE_CODE_ENTRYPOINT"] = "athena"
        return env
    }
}

// MARK: - LineSplitter

/// Reassembles NDJSON lines from arbitrarily chunked pipe reads.
///
/// `readabilityHandler` delivers whatever bytes happen to be available, which
/// routinely splits a JSON line in half — and agent frames are frequently
/// larger than the pipe buffer, so this is the common case, not an edge one.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let emit: @Sendable (String) -> Void

    init(emit: @escaping @Sendable (String) -> Void) {
        self.emit = emit
    }

    func consume(_ data: Data) {
        var completed: [String] = []
        lock.lock()
        buffer.append(data)
        while let index = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if let line = String(data: lineData, encoding: .utf8) { completed.append(line) }
        }
        lock.unlock()
        for line in completed { emit(line) }
    }

    /// Emits any trailing bytes not terminated by a newline.
    func flush() {
        lock.lock()
        let remainder = buffer
        buffer = Data()
        lock.unlock()
        guard !remainder.isEmpty, let line = String(data: remainder, encoding: .utf8) else { return }
        emit(line)
    }
}

// MARK: - ErrorSink

/// Thread-safe stderr accumulator — the handler fires on a Dispatch thread
/// while the actor reads it at termination.
private final class ErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        // Keep the tail only — a chatty agent must not grow this unbounded.
        storage += chunk
        if storage.count > 8_000 { storage = String(storage.suffix(8_000)) }
    }
}
