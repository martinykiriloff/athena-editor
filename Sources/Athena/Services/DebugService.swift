// DebugService.swift
// Athena — manages DAP (Swift/Python) and CDP (Node.js/Chrome/Next.js) debug sessions.
// Swift 6, strict concurrency.

import Foundation

// MARK: - DebugService

actor DebugService {

    // Callbacks stored as nonisolated(unsafe) so they can be called without
    // crossing actor isolation into a MainActor.run {} closure.
    nonisolated(unsafe) private var cbStateChange: ((DebugState) -> Void)?
    nonisolated(unsafe) private var cbOutput:      ((String) -> Void)?
    nonisolated(unsafe) private var cbStopped:     ((DebugStop) -> Void)?

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

    func launch(_ config: LaunchConfig, workspaceURL: URL?, breakpointsByFile: [String: [Int]]) async throws {
        if isCDPType(config.type) {
            try await launchCDP(config, workspaceURL: workspaceURL, breakpoints: breakpointsByFile)
        } else {
            try await launchDAP(config, workspaceURL: workspaceURL, breakpoints: breakpointsByFile)
        }
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
                    // Use urlRegex so source-mapped filenames match.
                    let filename = (URL(fileURLWithPath: filePath).lastPathComponent)
                        .replacingOccurrences(of: ".", with: "\\.")
                    _ = try? await cdp.send("Debugger.setBreakpointByUrl", params: [
                        "urlRegex":   ".*\(filename).*",
                        "lineNumber": line - 1
                    ])
                } else {
                    _ = try? await cdp.send("Debugger.setBreakpointByUrl", params: [
                        "url":        "file://\(filePath)",
                        "lineNumber": line - 1
                    ])
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
        if isCDP { _ = try await cdpClient?.send("Debugger.resume")
        } else    { _ = try await dapClient.request("continue", args: ["threadId": threadId]) }
    }

    func stepOver(threadId: Int = 1) async throws {
        if isCDP { _ = try await cdpClient?.send("Debugger.stepOver")
        } else    { _ = try await dapClient.request("next", args: ["threadId": threadId]) }
    }

    func stepIn(threadId: Int = 1) async throws {
        if isCDP { _ = try await cdpClient?.send("Debugger.stepInto")
        } else    { _ = try await dapClient.request("stepIn", args: ["threadId": threadId]) }
    }

    func stepOut(threadId: Int = 1) async throws {
        if isCDP { _ = try await cdpClient?.send("Debugger.stepOut")
        } else    { _ = try await dapClient.request("stepOut", args: ["threadId": threadId]) }
    }

    func pause(threadId: Int = 1) async throws {
        if isCDP { _ = try await cdpClient?.send("Debugger.pause")
        } else    { _ = try await dapClient.request("pause", args: ["threadId": threadId]) }
    }

    func disconnect() async {
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
                let resp  = try? await cdp.send("Runtime.getProperties", params: [
                    "objectId": objectId, "ownProperties": true, "generatePreview": false
                ])
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
