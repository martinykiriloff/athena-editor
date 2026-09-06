// DebugService.swift
// Athena — manages DAP (Swift/Python), CDP (Node.js/Chrome/Next.js) and SFCC (SDAPI) debug sessions.
// Swift 6, strict concurrency.

import Foundation

// MARK: - DebugService

actor DebugService {

    // Every read/write of these three happens from DebugService's own
    // actor-isolated methods (the MainActor hop already happens inside the
    // wrapped closure itself, via `Task { @MainActor in ... }` in
    // `setCallbacks` below) — plain actor-isolated storage, no
    // `nonisolated(unsafe)` needed.
    private var cbStateChange: (@Sendable (DebugState) -> Void)?
    private var cbOutput:      (@Sendable (String) -> Void)?
    private var cbStopped:     (@Sendable (DebugStop) -> Void)?

    // DAP session (Swift / Python)
    private let dapClient = DAPClient()
    private var dapEventTask: Task<Void, Never>?

    // CDP session (Node.js / Chrome / Next.js)
    private var cdpClient:    CDPClient? = nil
    private var cdpProcess:   Process?   = nil
    private var cdpEventTask: Task<Void, Never>? = nil
    private var isCDP:        Bool = false
    // Paused call frames from the last Debugger.paused event.
    private var cdpFrames:    [[String: Any]] = []

    // SFCC session (Script Debugger API, ADR 0002)
    private var sfccSession:  SFCCDebugSession? = nil
    private var isSFCC:       Bool { sfccSession != nil }

    // MARK: - Callback wiring

    func setCallbacks(
        onStateChange: @escaping @MainActor (DebugState) -> Void,
        onOutput:      @escaping @MainActor (String) -> Void,
        onStopped:     @escaping @MainActor (DebugStop) -> Void
    ) {
        cbStateChange = { s in Task { @MainActor in onStateChange(s) } }
        cbOutput      = { t in Task { @MainActor in onOutput(t) } }
        cbStopped     = { d in Task { @MainActor in onStopped(d) } }
    }

    // MARK: - Launch

    /// `sfccConnection` is the workspace's active SFCC connection, the last
    /// credential fallback for "prophet" configs (ADR 0002); ignored otherwise.
    func launch(_ config: LaunchConfig, workspaceURL: URL?, breakpointsByFile: [String: [Int]],
                sfccConnection: SFCCConnection? = nil) async throws {
        if config.isSFCC {
            try await launchSFCC(config, workspaceURL: workspaceURL, breakpoints: breakpointsByFile,
                                 connection: sfccConnection)
        } else if isCDPType(config.type) {
            try await launchCDP(config, workspaceURL: workspaceURL, breakpoints: breakpointsByFile)
        } else {
            try await launchDAP(config, workspaceURL: workspaceURL, breakpoints: breakpointsByFile)
        }
    }

    // MARK: - SFCC launch (Script Debugger API)

    private func launchSFCC(_ config: LaunchConfig, workspaceURL: URL?, breakpoints: [String: [Int]],
                            connection: SFCCConnection?) async throws {
        let dwJSON = workspaceURL.flatMap { Self.loadDWJSON(in: $0) }
        let credentials = try Self.resolveSFCCCredentials(config: config, dwJSON: dwJSON, connection: connection)

        var roots: [URL] = []
        if let ws = workspaceURL {
            if let conn = connection {
                roots.append(SFCCService.cartridgesRoot(connection: conn, workspaceURL: ws))
            }
            if let rel = dwJSON?.cartridgesPath {
                roots.append(rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : ws.appendingPathComponent(rel))
            }
            roots.append(ws)
        }
        var found: [String: URL] = [:]
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            for (name, url) in SFCCService.discoverCartridges(under: root) where found[name] == nil {
                found[name] = url
            }
        }
        let map = SFCCCartridgeMap(cartridges: found)
        cbOutput?("[SFCC] \(found.count) cartridge(s) found locally; connecting to \(credentials.hostname)…\n")

        let session = SFCCDebugSession(
            client: try SDAPIClient(credentials: credentials),
            cartridges: map,
            onStateChange: cbStateChange ?? { _ in },
            onOutput: cbOutput ?? { _ in },
            onStopped: cbStopped ?? { _ in }
        )
        sfccSession = session
        do {
            try await session.start(breakpointsByFile: breakpoints)
        } catch is CancellationError {
            // Stop was pressed while the sandbox handshake was in flight;
            // the session already cleaned up after itself.
            sfccSession = nil
            throw DAPError.launchFailed("stopped before the sandbox session was established")
        } catch {
            sfccSession = nil
            throw error
        }
    }

    /// Pushes a breakpoint toggle into a live session. SFCC replaces the
    /// sandbox's whole set (SDAPI only appends); DAP re-sends the changed
    /// file. CDP breakpoints aren't tracked by id yet, so a toggle there
    /// takes effect on the next launch.
    func updateBreakpoints(changedFile: String, lines: [Int], allByFile: [String: [Int]]) async throws {
        if let sfcc = sfccSession {
            try await sfcc.updateBreakpoints(byFile: allByFile)
            return
        }
        if isCDP { return }
        _ = try await dapClient.request("setBreakpoints", args: [
            "source": ["path": changedFile],
            "breakpoints": lines.map { ["line": $0] }
        ])
    }

    /// Launch config first (Prophet's launch.json keys), then dw.json, then
    /// the active Athena SFCC connection. Hostname, username and password are
    /// all required; the code version is informational for the debugger.
    static func resolveSFCCCredentials(config: LaunchConfig, dwJSON: DWJSONConfig?,
                                       connection: SFCCConnection?) throws -> SFCCDebugCredentials {
        func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
        guard let hostname = nonEmpty(config.hostname) ?? nonEmpty(dwJSON?.hostname) ?? nonEmpty(connection?.hostname) else {
            throw SDAPIError.missingCredentials("no hostname — add one to launch.json, dw.json, or an SFCC connection")
        }
        guard let username = nonEmpty(config.username) ?? nonEmpty(dwJSON?.username) ?? nonEmpty(connection?.username) else {
            throw SDAPIError.missingCredentials("no username for \(hostname)")
        }
        guard let password = nonEmpty(config.password) ?? nonEmpty(dwJSON?.password) ?? nonEmpty(connection?.password) else {
            throw SDAPIError.missingCredentials("no password for \(username)@\(hostname)")
        }
        let codeVersion = nonEmpty(config.codeVersion) ?? nonEmpty(dwJSON?.codeVersion) ?? nonEmpty(connection?.codeVersion)
        return SFCCDebugCredentials(hostname: hostname, username: username, password: password, codeVersion: codeVersion)
    }

    static func loadDWJSON(in workspaceURL: URL) -> DWJSONConfig? {
        let url = workspaceURL.appendingPathComponent("dw.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return DWJSONConfig.parse(data)
    }

    // MARK: - DAP launch (Swift / Python / legacy Node via @vscode/js-debug)

    private func launchDAP(_ config: LaunchConfig, workspaceURL: URL?, breakpoints: [String: [Int]]) async throws {
        let adapterPath = try resolveAdapter(for: config)
        try await dapClient.start(adapterPath: adapterPath)

        dapEventTask = Task { [weak self] in
            guard let self else { return }
            for await raw in await self.dapClient.events {
                await self.handleDAPEvent(raw.json)
            }
        }

        let capabilities = try await dapClient.request("initialize", args: [
            "adapterID":              config.type,
            "clientID":               "athena",
            "clientName":             "Athena",
            "pathFormat":             "path",
            "linesStartAt1":          true,
            "columnsStartAt1":        true,
            "supportsVariableType":   true,
            "supportsRunInTerminalRequest": false
        ])
        _ = capabilities

        let program = resolveVariable(config.program, workspaceURL: workspaceURL)
        var launchArgs: [String: Any] = [
            "program":     program,
            "args":        config.args,
            "cwd":         resolveVariable(config.cwd, workspaceURL: workspaceURL),
            "stopOnEntry": config.stopOnEntry,
            "noDebug":     false
        ]
        if !config.env.isEmpty { launchArgs["env"] = config.env }

        if config.request == "launch" {
            _ = try await dapClient.request("launch", args: launchArgs)
        } else {
            _ = try await dapClient.request("attach", args: launchArgs)
        }

        for (filePath, lines) in breakpoints {
            let bps = lines.map { ["line": $0] }
            _ = try? await dapClient.request("setBreakpoints", args: [
                "source": ["path": filePath],
                "breakpoints": bps
            ])
        }

        _ = try? await dapClient.request("configurationDone")
        cbStateChange?(.running)
    }

    // MARK: - CDP launch (Node.js / Chrome / Next.js)

    private func launchCDP(_ config: LaunchConfig, workspaceURL: URL?, breakpoints: [String: [Int]]) async throws {
        let port = config.debugPort ?? (isBrowserType(config.type) ? 9222 : 9229)
        isCDP = true

        // 1. Spawn the target process (launch mode only).
        if config.request == "launch" {
            if isBrowserType(config.type) {
                // Launch Chrome/Chromium with remote debugging enabled.
                let chromePath = try CDPClient.findChrome()
                let pageURL    = config.url ?? "http://localhost:3000"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: chromePath)
                p.arguments = [
                    "--remote-debugging-port=\(port)",
                    "--no-first-run",
                    "--no-default-browser-check",
                    "--disable-background-networking",
                    "--user-data-dir=/tmp/athena-chrome-\(port)",
                    pageURL
                ]
                p.terminationHandler = { [weak self] _ in Task { await self?.cdpProcessEnded() } }
                try p.run()
                cdpProcess = p
                cbOutput?("[Athena] Chrome launched on port \(port)…\n")
            } else {
                // Launch Node.js with --inspect-brk so it pauses before any user code.
                let program = resolveVariable(config.program, workspaceURL: workspaceURL)
                guard !program.isEmpty else { throw DAPError.launchFailed("No program specified.") }
                let node  = findNodeBinary() ?? "node"
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: shell)
                p.arguments = ["-l", "-c", "\(node) --inspect-brk=\(port) \(program)"]
                if let ws = workspaceURL { p.currentDirectoryURL = ws }
                if !config.env.isEmpty {
                    var env = ProcessInfo.processInfo.environment
                    config.env.forEach { env[$0] = $1 }
                    p.environment = env
                }
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError  = pipe
                pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
                    let data = fh.availableData
                    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
                    Task { await self?.cdpOutput(text) }
                }
                p.terminationHandler = { [weak self] _ in Task { await self?.cdpProcessEnded() } }
                try p.run()
                cdpProcess = p
                cbOutput?("[Athena] Node.js launched on port \(port)…\n")
            }
        }

        // 2. Poll for the CDP WebSocket endpoint.
        let filter = isBrowserType(config.type) ? (config.url ?? "localhost") : nil
        let wsURL  = try await CDPClient.targetWebSocketURL(port: port, pageURLContains: filter)
        let cdp    = CDPClient()
        await cdp.connect(to: wsURL)
        cdpClient = cdp
        cbOutput?("[Athena] CDP connected (\(wsURL))\n")

        // 3. Subscribe to events before enabling the debugger.
        cdpEventTask = Task { [weak self] in
            guard let self else { return }
            for await msg in await cdp.events {
                await self.handleCDPEvent(msg)
            }
            await self.cdpProcessEnded()
        }

        // 4. Enable protocol domains.
        _ = try await cdp.send("Debugger.enable")
        _ = try? await cdp.send("Runtime.enable")
        _ = try? await cdp.send("Console.enable")

        // 5. Set breakpoints.
        let isChrome = isBrowserType(config.type)
        for (filePath, lines) in breakpoints {
            for line in lines {
                if isChrome {
                    let filename = (URL(fileURLWithPath: filePath).lastPathComponent)
                        .replacingOccurrences(of: ".", with: "\\.")
                    // cdpJSON keeps [String: Any] inside the DebugService actor — only Data crosses.
                    _ = try? await cdp.send("Debugger.setBreakpointByUrl",
                        paramsJSON: cdpJSON(["urlRegex": ".*\(filename).*", "lineNumber": line - 1]))
                } else {
                    _ = try? await cdp.send("Debugger.setBreakpointByUrl",
                        paramsJSON: cdpJSON(["url": "file://\(filePath)", "lineNumber": line - 1]))
                }
            }
        }

        // 6. Node pauses immediately with --inspect-brk; release it into user code.
        if !isBrowserType(config.type) {
            _ = try? await cdp.send("Runtime.runIfWaitingForDebugger")
        }

        cbStateChange?(.running)
    }

    // MARK: - Controls

    func continueExecution(threadId: Int = 1) async throws {
        if let sfcc = sfccSession { try await sfcc.resume(); return }
        if isCDP { _ = try await cdpClient?.send("Debugger.resume")
        } else    { _ = try await dapClient.request("continue", args: ["threadId": threadId]) }
    }

    func stepOver(threadId: Int = 1) async throws {
        if let sfcc = sfccSession { try await sfcc.step(.over); return }
        if isCDP { _ = try await cdpClient?.send("Debugger.stepOver")
        } else    { _ = try await dapClient.request("next", args: ["threadId": threadId]) }
    }

    func stepIn(threadId: Int = 1) async throws {
        if let sfcc = sfccSession { try await sfcc.step(.into); return }
        if isCDP { _ = try await cdpClient?.send("Debugger.stepInto")
        } else    { _ = try await dapClient.request("stepIn", args: ["threadId": threadId]) }
    }

    func stepOut(threadId: Int = 1) async throws {
        if let sfcc = sfccSession { try await sfcc.step(.out); return }
        if isCDP { _ = try await cdpClient?.send("Debugger.stepOut")
        } else    { _ = try await dapClient.request("stepOut", args: ["threadId": threadId]) }
    }

    func pause(threadId: Int = 1) async throws {
        if isSFCC {
            // SDAPI halts only at breakpoints; there is no "pause now".
            cbOutput?("[SFCC] Pause isn't supported by the Script Debugger API — set a breakpoint instead\n")
            return
        }
        if isCDP { _ = try await cdpClient?.send("Debugger.pause")
        } else    { _ = try await dapClient.request("pause", args: ["threadId": threadId]) }
    }

    func disconnect() async {
        if let sfcc = sfccSession {
            await sfcc.stop()
            sfccSession = nil
            return
        }
        if isCDP {
            cdpEventTask?.cancel()
            cdpEventTask = nil
            if let cdp = cdpClient {
                _ = try? await cdp.send("Debugger.disable")
                await cdp.disconnect()
            }
            cdpClient  = nil
            cdpProcess?.terminate()
            cdpProcess = nil
            cdpFrames  = []
            isCDP      = false
        } else {
            _ = try? await dapClient.request("disconnect", args: ["restart": false])
            await dapClient.stop()
            dapEventTask?.cancel()
            dapEventTask = nil
        }
        cbStateChange?(.stopped)
    }

    // MARK: - Stack & Variables

    func fetchStackFrames(threadId: Int = 1) async throws -> [DebugStackFrame] {
        if let sfcc = sfccSession { return try await sfcc.stackFrames() }
        if isCDP {
            return cdpFrames.enumerated().compactMap { idx, frame -> DebugStackFrame? in
                let raw  = frame["functionName"] as? String ?? ""
                let name = raw.isEmpty ? "<anonymous>" : raw
                let url  = frame["url"] as? String ?? ""
                let loc  = frame["location"] as? [String: Any]
                let line = (loc?["lineNumber"] as? Int ?? 0) + 1
                let col  = (loc?["columnNumber"] as? Int ?? 0) + 1
                let fileURL: URL? = url.hasPrefix("file://") ? URL(string: url)
                                  : url.hasPrefix("http")    ? URL(string: url)
                                  : nil
                return DebugStackFrame(id: idx, name: name, sourceURL: fileURL, line: line, column: col)
            }
        }
        let body   = try await dapClient.request("stackTrace", args: ["threadId": threadId, "levels": 20])
        let frames = body.json["stackFrames"] as? [[String: Any]] ?? []
        return frames.compactMap { f -> DebugStackFrame? in
            guard let id   = f["id"]   as? Int,
                  let name = f["name"] as? String else { return nil }
            let line = f["line"]   as? Int ?? 0
            let col  = f["column"] as? Int ?? 0
            let src  = f["source"] as? [String: Any]
            let url  = (src?["path"] as? String).flatMap { URL(string: "file://\($0)") }
            return DebugStackFrame(id: id, name: name, sourceURL: url, line: line, column: col)
        }
    }

    func fetchVariables(frameId: Int) async throws -> [DebugVariable] {
        if let sfcc = sfccSession { return try await sfcc.variables(frameIndex: frameId) }
        if isCDP {
            guard frameId < cdpFrames.count else { return [] }
            let frame      = cdpFrames[frameId]
            let scopeChain = frame["scopeChain"] as? [[String: Any]] ?? []
            var result: [DebugVariable] = []
            for scope in scopeChain.prefix(2) {
                let kind = scope["type"] as? String ?? ""
                guard kind == "local" || kind == "closure" || kind == "block" else { continue }
                guard let obj      = scope["object"] as? [String: Any],
                      let objectId = obj["objectId"] as? String,
                      let cdp      = cdpClient else { continue }
                let resp  = try? await cdp.send("Runtime.getProperties",
                    paramsJSON: cdpJSON(["objectId": objectId, "ownProperties": true, "generatePreview": false]))
                let props = resp?.json["result"] as? [[String: Any]] ?? []
                for prop in props {
                    guard let name = prop["name"] as? String, !name.hasPrefix("__") else { continue }
                    let val = prop["value"] as? [String: Any]
                    let display: String
                    if let desc = val?["description"] as? String { display = desc }
                    else if let v = val?["value"] { display = "\(v)" }
                    else { display = "undefined" }
                    result.append(DebugVariable(name: name, value: display,
                                                type: val?["type"] as? String,
                                                variablesReference: 0))
                }
            }
            return result
        }
        let scopeBody = try await dapClient.request("scopes", args: ["frameId": frameId])
        let scopes    = scopeBody.json["scopes"] as? [[String: Any]] ?? []
        var result: [DebugVariable] = []
        for scope in scopes.prefix(2) {
            guard let ref = scope["variablesReference"] as? Int, ref > 0 else { continue }
            let varBody = try await dapClient.request("variables", args: ["variablesReference": ref])
            let vars    = varBody.json["variables"] as? [[String: Any]] ?? []
            result += vars.compactMap { v -> DebugVariable? in
                guard let name  = v["name"]  as? String,
                      let value = v["value"] as? String else { return nil }
                return DebugVariable(name: name, value: value,
                                     type: v["type"] as? String,
                                     variablesReference: v["variablesReference"] as? Int ?? 0)
            }
        }
        return result
    }

    // MARK: - Evaluate (watch expressions + REPL console, plan.md item 24)

    /// Evaluates an arbitrary expression against a stack frame, following the
    /// standard DAP `evaluate` request (`{expression, frameId, context}` →
    /// `{result, type, variablesReference}`) for DAP sessions, or the CDP
    /// equivalent (`Debugger.evaluateOnCallFrame` when a paused call frame is
    /// available, else `Runtime.evaluate`) for CDP sessions. `context` is
    /// DAP's own vocabulary (`"watch"`, `"repl"`, `"hover"`…) — CDP doesn't
    /// take one, so it's ignored on that path.
    func evaluate(expression: String, frameId: Int?, context: String) async throws -> DAPEvaluateResult {
        if let sfcc = sfccSession { return try await sfcc.evaluate(expression, frameIndex: frameId) }
        if isCDP {
            guard let cdp = cdpClient else { throw DAPError.sessionEnded }
            let resp: CDPClient.Response
            if let frameId, frameId < cdpFrames.count,
               let callFrameId = cdpFrames[frameId]["callFrameId"] as? String {
                resp = try await cdp.send("Debugger.evaluateOnCallFrame", paramsJSON: cdpJSON([
                    "callFrameId": callFrameId, "expression": expression, "returnByValue": false
                ]))
            } else {
                resp = try await cdp.send("Runtime.evaluate", paramsJSON: cdpJSON([
                    "expression": expression, "returnByValue": false
                ]))
            }
            if let message = Self.cdpEvaluateExceptionMessage(resp.json) {
                throw DAPError.requestFailed(message)
            }
            return Self.parseCDPEvaluateResponse(resp.json)
        }
        var args: [String: Any] = ["expression": expression, "context": context]
        if let frameId { args["frameId"] = frameId }
        let body = try await dapClient.request("evaluate", args: args)
        return Self.parseDAPEvaluateResponse(body.json)
    }

    /// Parses a DAP `evaluate` response body. Pure and file-scope testable
    /// (static members of an actor aren't isolated) without spinning up a
    /// `DAPClient`/adapter process — mirrors `GitService.parsePorcelainStatus`'s
    /// "extract the parsing seam" convention.
    static func parseDAPEvaluateResponse(_ json: [String: Any]) -> DAPEvaluateResult {
        DAPEvaluateResult(
            result: json["result"] as? String ?? "",
            type: json["type"] as? String,
            variablesReference: json["variablesReference"] as? Int ?? 0
        )
    }

    /// Parses a CDP `Debugger.evaluateOnCallFrame`/`Runtime.evaluate` response,
    /// preferring `result.description` (present for objects/errors) then
    /// falling back to the raw `value` — matching `fetchVariables`'s existing
    /// CDP display-string convention.
    static func parseCDPEvaluateResponse(_ json: [String: Any]) -> DAPEvaluateResult {
        let result = json["result"] as? [String: Any] ?? [:]
        let display: String
        if let desc = result["description"] as? String { display = desc }
        else if let v = result["value"] { display = "\(v)" }
        else { display = "undefined" }
        return DAPEvaluateResult(result: display, type: result["type"] as? String, variablesReference: 0)
    }

    /// Extracts a human-readable message from a CDP `exceptionDetails` payload,
    /// or `nil` if the response didn't fail.
    static func cdpEvaluateExceptionMessage(_ json: [String: Any]) -> String? {
        guard let exceptionDetails = json["exceptionDetails"] as? [String: Any] else { return nil }
        if let desc = (exceptionDetails["exception"] as? [String: Any])?["description"] as? String {
            return desc
        }
        return (exceptionDetails["text"] as? String) ?? "Evaluation failed"
    }

    // MARK: - DAP events

    private func handleDAPEvent(_ event: [String: Any]) async {
        guard let name = event["event"] as? String else { return }
        let body = event["body"] as? [String: Any] ?? [:]
        switch name {
        case "initialized":
            cbStateChange?(.running)
        case "stopped":
            let reason   = body["reason"]   as? String ?? "pause"
            let threadId = body["threadId"] as? Int    ?? 1
            let file     = (body["source"] as? [String: Any])?["path"] as? String
            let line     = body["line"] as? Int
            cbStateChange?(.paused(reason: reason))
            cbStopped?(DebugStop(reason: reason, threadId: threadId, filePath: file, line: line))
        case "continued":
            cbStateChange?(.running)
        case "output":
            let text = body["output"] as? String ?? ""
            if !text.isEmpty { cbOutput?(text) }
        case "terminated", "exited":
            await dapClient.stop()
            dapEventTask?.cancel()
            dapEventTask = nil
            cbStateChange?(.stopped)
        default:
            break
        }
    }

    // MARK: - CDP events

    private func handleCDPEvent(_ msg: CDPClient.Msg) async {
        guard let method = msg.json["method"] as? String else { return }
        let params = msg.json["params"] as? [String: Any] ?? [:]

        switch method {
        case "Debugger.paused":
            let frames = params["callFrames"] as? [[String: Any]] ?? []
            cdpFrames  = frames
            let reason = params["reason"] as? String ?? "breakpoint"
            let top    = frames.first
            let loc    = top?["location"] as? [String: Any]
            let line   = (loc?["lineNumber"] as? Int ?? 0) + 1
            let url    = top?["url"] as? String ?? ""
            let path: String? = url.hasPrefix("file://") ? String(url.dropFirst(7)) : nil
            cbStateChange?(.paused(reason: reason))
            cbStopped?(DebugStop(reason: reason, threadId: 0, filePath: path, line: line))

        case "Debugger.resumed":
            cdpFrames = []
            cbStateChange?(.running)

        case "Runtime.consoleAPICalled":
            let args = params["args"] as? [[String: Any]] ?? []
            let text = args.compactMap { a -> String? in
                if let v = a["value"] { return "\(v)" }
                return a["description"] as? String
            }.joined(separator: " ")
            if !text.isEmpty { cbOutput?("[console] \(text)\n") }

        case "Console.messageAdded":
            if let msg2 = params["message"] as? [String: Any],
               let text = msg2["text"] as? String, !text.isEmpty {
                cbOutput?("[console] \(text)\n")
            }

        case "_disconnect":
            await cdpProcessEnded()

        default:
            break
        }
    }

    // MARK: - CDP helpers

    // Encodes a [String: Any] dict to JSON Data within the actor so [String: Any]
    // never crosses the actor boundary — only the Sendable Data value does.
    private func cdpJSON(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    private func cdpOutput(_ text: String) {
        cbOutput?(text)
    }

    private func cdpProcessEnded() async {
        cdpEventTask?.cancel()
        cdpEventTask = nil
        if let cdp = cdpClient { await cdp.disconnect() }
        cdpClient  = nil
        cdpProcess = nil
        cdpFrames  = []
        isCDP      = false
        cbStateChange?(.stopped)
    }

    // MARK: - Adapter resolution (DAP)

    private func resolveAdapter(for config: LaunchConfig) throws -> String {
        switch config.type {
        case "lldb", "swift":                    return try findLLDBDAP()
        case "python":                           return try findPythonDebugPy()
        case "node", "typescript", "pwa-node":  return try findJSDebug()
        default:
            throw DAPError.adapterNotFound("No adapter for type '\(config.type)'")
        }
    }

    private func findLLDBDAP() throws -> String {
        for path in ["/usr/bin/lldb-dap", "/usr/local/bin/lldb-dap"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        let xcrun = Process()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["--find", "lldb-dap"]
        let pipe = Pipe()
        xcrun.standardOutput = pipe
        xcrun.standardError  = Pipe()
        try? xcrun.run()
        xcrun.waitUntilExit()
        if let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !out.isEmpty, FileManager.default.fileExists(atPath: out) { return out }
        throw DAPError.adapterNotFound("lldb-dap not found. Install Xcode command line tools.")
    }

    private func findPythonDebugPy() throws -> String {
        for path in ["/usr/local/bin/python3", "/usr/bin/python3", "/opt/homebrew/bin/python3"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        throw DAPError.adapterNotFound("python3 not found.")
    }

    private func findJSDebug() throws -> String {
        for path in ["/usr/local/lib/node_modules/@vscode/js-debug/src/dapDebugServer.js",
                     "/usr/lib/node_modules/@vscode/js-debug/src/dapDebugServer.js"] {
            if FileManager.default.fileExists(atPath: path),
               let node = findNodeBinary() { return node }
        }
        throw DAPError.adapterNotFound("@vscode/js-debug not found. Run: npm install -g @vscode/js-debug")
    }

    private func findNodeBinary() -> String? {
        for path in ["/usr/local/bin/node", "/usr/bin/node", "/opt/homebrew/bin/node"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private func resolveVariable(_ value: String, workspaceURL: URL?) -> String {
        var result = value
        if let ws = workspaceURL {
            result = result.replacingOccurrences(of: "${workspaceFolder}", with: ws.path)
        }
        return result
    }

    // MARK: - Type helpers

    private func isCDPType(_ type: String) -> Bool {
        switch type { case "node-cdp", "chrome", "nextjs": return true; default: return false }
    }

    private func isBrowserType(_ type: String) -> Bool {
        type == "chrome" || type == "nextjs"
    }
}

// MARK: - DebugStop

struct DebugStop: Sendable {
    let reason: String
    let threadId: Int
    let filePath: String?
    let line: Int?
}
