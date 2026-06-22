// DebugService.swift
// Athena — manages a DAP debug session lifecycle.
// Swift 6, strict concurrency.

import Foundation

// MARK: - DebugService

actor DebugService {

    // Callbacks stored as nonisolated(unsafe) so they can be captured and called
    // from MainActor.run { } without crossing actor isolation.
    nonisolated(unsafe) private var cbStateChange: ((DebugState) -> Void)?
    nonisolated(unsafe) private var cbOutput:      ((String) -> Void)?
    nonisolated(unsafe) private var cbStopped:     ((DebugStop) -> Void)?

    private let client = DAPClient()
    private var eventTask: Task<Void, Never>?

    // MARK: - Callback wiring

    func setCallbacks(
        onStateChange: @escaping @MainActor (DebugState) -> Void,
        onOutput:      @escaping @MainActor (String) -> Void,
        onStopped:     @escaping @MainActor (DebugStop) -> Void
    ) {
        // Wrap in MainActor.assumeIsolated to keep callers on MainActor.
        cbStateChange = { s in Task { @MainActor in onStateChange(s) } }
        cbOutput      = { t in Task { @MainActor in onOutput(t) } }
        cbStopped     = { d in Task { @MainActor in onStopped(d) } }
    }

    // MARK: - Launch

    func launch(_ config: LaunchConfig, workspaceURL: URL?, breakpointsByFile: [String: [Int]]) async throws {
        let adapterPath = try resolveAdapter(for: config)

        try await client.start(adapterPath: adapterPath)

        // Start listening to events before initialize.
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await raw in await self.client.events {
                await self.handleEvent(raw.json)
            }
        }

        // 1. Initialize the adapter.
        let capabilities = try await client.request("initialize", args: [
            "adapterID":              config.type,
            "clientID":               "athena",
            "clientName":             "Athena",
            "pathFormat":             "path",
            "linesStartAt1":          true,
            "columnsStartAt1":        true,
            "supportsVariableType":   true,
            "supportsRunInTerminalRequest": false
        ])
        _ = capabilities   // store if needed for future capability checks

        // 2. Launch or attach.
        let program = resolveVariable(config.program, workspaceURL: workspaceURL)
        var launchArgs: [String: Any] = [
            "program":      program,
            "args":         config.args,
            "cwd":          resolveVariable(config.cwd, workspaceURL: workspaceURL),
            "stopOnEntry":  config.stopOnEntry,
            "noDebug":      false
        ]
        if !config.env.isEmpty { launchArgs["env"] = config.env }

        if config.request == "launch" {
            _ = try await client.request("launch", args: launchArgs)
        } else {
            _ = try await client.request("attach", args: launchArgs)
        }

        // 3. Set breakpoints in each file.
        for (filePath, lines) in breakpointsByFile {
            let bps = lines.map { ["line": $0] }
            _ = try? await client.request("setBreakpoints", args: [
                "source": ["path": filePath],
                "breakpoints": bps
            ])
        }

        // 4. Finish configuration.
        _ = try? await client.request("configurationDone")

        cbStateChange?(.running)
    }

    // MARK: - Controls

    func continueExecution(threadId: Int = 1) async throws {
        _ = try await client.request("continue", args: ["threadId": threadId])
    }

    func stepOver(threadId: Int = 1) async throws {
        _ = try await client.request("next", args: ["threadId": threadId])
    }

    func stepIn(threadId: Int = 1) async throws {
        _ = try await client.request("stepIn", args: ["threadId": threadId])
    }

    func stepOut(threadId: Int = 1) async throws {
        _ = try await client.request("stepOut", args: ["threadId": threadId])
    }

    func pause(threadId: Int = 1) async throws {
        _ = try await client.request("pause", args: ["threadId": threadId])
    }

    func disconnect() async {
        _ = try? await client.request("disconnect", args: ["restart": false])
        await client.stop()
        eventTask?.cancel()
        eventTask = nil
        cbStateChange?(.stopped)
    }

    // MARK: - Stack & Variables

    func fetchStackFrames(threadId: Int = 1) async throws -> [DebugStackFrame] {
        let body = try await client.request("stackTrace", args: ["threadId": threadId, "levels": 20])
        let frames = body.json["stackFrames"] as? [[String: Any]] ?? []
        return frames.compactMap { frame -> DebugStackFrame? in
            guard let id = frame["id"] as? Int,
                  let name = frame["name"] as? String else { return nil }
            let line = frame["line"] as? Int ?? 0
            let col  = frame["column"] as? Int ?? 0
            let src  = frame["source"] as? [String: Any]
            let path = src?["path"] as? String
            let url  = path.flatMap { URL(string: "file://\($0)") }
            return DebugStackFrame(id: id, name: name, sourceURL: url, line: line, column: col)
        }
    }

    func fetchVariables(frameId: Int) async throws -> [DebugVariable] {
        // First get scopes for the frame.
        let scopeBody = try await client.request("scopes", args: ["frameId": frameId])
        let scopes = scopeBody.json["scopes"] as? [[String: Any]] ?? []

        var result: [DebugVariable] = []
        for scope in scopes.prefix(2) {   // locals + closure
            guard let ref = scope["variablesReference"] as? Int, ref > 0 else { continue }
            let varBody = try await client.request("variables", args: ["variablesReference": ref])
            let vars = varBody.json["variables"] as? [[String: Any]] ?? []
            result += vars.compactMap { v -> DebugVariable? in
                guard let name = v["name"] as? String,
                      let value = v["value"] as? String else { return nil }
                return DebugVariable(
                    name: name,
                    value: value,
                    type: v["type"] as? String,
                    variablesReference: v["variablesReference"] as? Int ?? 0
                )
            }
        }
        return result
    }

    // MARK: - Events

    private func handleEvent(_ event: [String: Any]) async {
        guard let name = event["event"] as? String else { return }
        let body = event["body"] as? [String: Any] ?? [:]

        switch name {
        case "initialized":
            cbStateChange?(.running)

        case "stopped":
            let reason   = body["reason"] as? String ?? "pause"
            let threadId = body["threadId"] as? Int ?? 1
            let file     = (body["source"] as? [String: Any])?["path"] as? String
            let line     = body["line"] as? Int
            let stop     = DebugStop(reason: reason, threadId: threadId, filePath: file, line: line)
            cbStateChange?(.paused(reason: reason))
            cbStopped?(stop)

        case "continued":
            cbStateChange?(.running)

        case "output":
            let text = body["output"] as? String ?? ""
            if !text.isEmpty { cbOutput?(text) }

        case "terminated", "exited":
            await client.stop()
            eventTask?.cancel()
            eventTask = nil
            cbStateChange?(.stopped)

        default:
            break
        }
    }

    // MARK: - Adapter resolution

    private func resolveAdapter(for config: LaunchConfig) throws -> String {
        switch config.type {
        case "lldb", "swift":
            return try findLLDBDAP()
        case "python":
            return try findPythonDebugPy()
        case "node", "typescript", "pwa-node":
            return try findJSDebug()
        default:
            throw DAPError.adapterNotFound("No adapter for type '\(config.type)'")
        }
    }

    private func findLLDBDAP() throws -> String {
        for path in ["/usr/bin/lldb-dap", "/usr/local/bin/lldb-dap"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // Try xcrun
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
           !out.isEmpty, FileManager.default.fileExists(atPath: out) {
            return out
        }
        throw DAPError.adapterNotFound("lldb-dap not found. Install Xcode command line tools.")
    }

    private func findPythonDebugPy() throws -> String {
        // debugpy ships its own DAP adapter launcher
        let candidates = ["/usr/local/bin/python3", "/usr/bin/python3", "/opt/homebrew/bin/python3"]
        for python in candidates {
            if FileManager.default.fileExists(atPath: python) {
                return python   // launcher path; args will be ["-m", "debugpy", ...]
            }
        }
        throw DAPError.adapterNotFound("python3 not found.")
    }

    private func findJSDebug() throws -> String {
        // Use the shell to find js-debug (installed by @vscode/js-debug)
        for path in ["/usr/local/lib/node_modules/@vscode/js-debug/src/dapDebugServer.js",
                     "/usr/lib/node_modules/@vscode/js-debug/src/dapDebugServer.js"] {
            if FileManager.default.fileExists(atPath: path) {
                if let node = findNodeBinary() { return node }
            }
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
}

// MARK: - DebugStop

struct DebugStop: Sendable {
    let reason: String
    let threadId: Int
    let filePath: String?
    let line: Int?
}
