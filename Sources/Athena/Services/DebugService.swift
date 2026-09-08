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

    /// Set when the adapter sends its `initialized` event. DAP requires
    /// breakpoints to be configured only after that event, and adapters may
    /// hold the `launch` response until `configurationDone` arrives.
    /// The focused editor's file, for `${file}` in a launch config.
    /// `--inspect-brk` always halts before user code, whatever the config
    /// says. That entry pause is swallowed unless the user asked to stop on
    /// entry — identified by CDP's own reason plus the fact that the session
    /// hasn't been released yet, not by "the first pause we see": the entry
    /// pause is delivered as soon as the debugger attaches, which is before
    /// breakpoints are even registered, so counting pauses swallowed the
    /// first real breakpoint hit instead.
    /// Breakpoints kept so they can be re-bound through a source map when a
    /// compiled script announces itself. A bundler (Next.js, Vite, tsc)
    /// serves generated JavaScript, so a breakpoint on the TypeScript the
    /// user wrote matches no script V8 ever loads.
    private var pendingSourceMappedBreakpoints: [String: [Int]] = [:]
    /// Source maps already fetched, keyed by the map's URL.
    private var sourceMapCache: [String: SourceMap] = [:]
    /// Generated scripts a breakpoint has been placed in, so a re-parse
    /// doesn't stack duplicates on the same line.
    private var boundSourceMappedLines: Set<String> = []
    /// The open folder, for turning a bundler's module name back into a file.
    private var currentWorkspaceURL: URL?
    /// Per-script source maps and URLs, so a pause in generated code can be
    /// reported at the line the user actually wrote.
    private var scriptMaps: [String: SourceMap] = [:]
    private var scriptURLs: [String: String] = [:]
    private var stopOnEntryRequested = false
    /// Breakpoints are registered before the entry halt is released, so user
    /// code can't run past them; these two track whichever order the pause
    /// event and that registration happen to arrive in.
    private var breakpointsRegistered = false
    private var entryPauseAwaitingResume = false
    private var cachedNodePath: String?
    private var currentFileURL: URL?
    private var dapInitialized = false
    /// Thread the adapter last stopped. `stackTrace` against a hardcoded
    /// thread 1 returns nothing on any adapter that numbers threads
    /// differently, which read as "paused with an empty call stack".
    private var lastStoppedThreadId: Int?

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
                currentFileURL: URL? = nil,
                sfccConnection: SFCCConnection? = nil) async throws {
        self.currentFileURL = currentFileURL
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
        try await dapClient.start(adapterPath: adapterPath, adapterArgs: adapterArguments(for: config))

        dapInitialized = false
        lastStoppedThreadId = nil
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

        // DAP's actual order, which this used to get wrong by awaiting
        // `launch` first: the adapter may hold that response until
        // `configurationDone`, and breakpoints set before the `initialized`
        // event are ignored. Sending launch without awaiting it, configuring
        // once `initialized` arrives, then collecting the response is what
        // every working client does — and what makes lldb-dap stop at a
        // breakpoint instead of failing or running straight through.
        let command = config.request == "launch" ? "launch" : "attach"
        let launchSeq = try await dapClient.beginRequest(command, args: launchArgs)

        await awaitDAPInitialized()

        for (filePath, lines) in breakpoints.sorted(by: { $0.key < $1.key }) {
            let bps = lines.sorted().map { ["line": $0] }
            _ = try? await dapClient.request("setBreakpoints", args: [
                "source": ["path": filePath, "name": (filePath as NSString).lastPathComponent],
                "breakpoints": bps,
                "sourceModified": false,
            ])
        }

        _ = try? await dapClient.request("configurationDone")
        _ = try await dapClient.awaitResponse(seq: launchSeq, timeout: .seconds(30))
        cbStateChange?(.running)
    }

    // MARK: - CDP launch (Node.js / Chrome / Next.js)

    private func launchCDP(_ config: LaunchConfig, workspaceURL: URL?, breakpoints: [String: [Int]]) async throws {
        let port = config.debugPort ?? (isBrowserType(config.type) ? 9222 : 9229)
        isCDP = true
        stopOnEntryRequested = config.stopOnEntry
        currentWorkspaceURL = workspaceURL
        anyBreakpointBound = false
        scriptMaps = [:]
        scriptURLs = [:]
        sourceMapCache = [:]
        boundSourceMappedLines = []
        breakpointsRegistered = false
        entryPauseAwaitingResume = false

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
                p.terminationHandler = { [weak self] finished in
                    let status = finished.terminationStatus
                    Task { await self?.cdpProcessEnded(exitStatus: status) }
                }
                try p.run()
                cdpProcess = p
                cbOutput?("[Athena] Chrome launched on port \(port)…\n")
            } else {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let command: String
                if config.type == "dev-server" {
                    // Start the project's dev script with the inspector
                    // switched on, rather than asking the user to remember
                    // NODE_OPTIONS and restart the server by hand. No
                    // --inspect-brk: a dev server should come up and serve.
                    guard let ws = workspaceURL else {
                        throw DAPError.launchFailed("Open a folder before starting its dev server.")
                    }
                    let script = config.program.isEmpty ? "dev" : config.program
                    // `next dev --inspect` is the supported switch. Setting
                    // NODE_OPTIONS instead puts the inspector on the npm
                    // wrapper, which holds none of the app's code — the
                    // child that renders it then fails to bind the same port.
                    command = "\(Self.packageManager(for: ws)) run \(script) -- --inspect=\(port)"
                } else {
                    // Launch Node.js with --inspect-brk so it pauses before any user code.
                    let program = resolveVariable(config.program, workspaceURL: workspaceURL)
                    guard !program.isEmpty else { throw DAPError.launchFailed("No program specified.") }
                    let node = findNodeBinary() ?? "node"
                    command = "\(node) --inspect-brk=\(port) \(program)"
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: shell)
                p.arguments = ["-l", "-c", command]
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
                p.terminationHandler = { [weak self] finished in
                    let status = finished.terminationStatus
                    Task { await self?.cdpProcessEnded(exitStatus: status) }
                }
                try p.run()
                cdpProcess = p
                cbOutput?("[Athena] Node.js launched on port \(port)…\n")
            }
        }

        // 2. Poll for the CDP WebSocket endpoint.
        let filter = isBrowserType(config.type) ? (config.url ?? "localhost") : nil
        // A dev server compiles before it listens, so give it longer than a
        // plain script gets.
        let wsURL = try await CDPClient.targetWebSocketURL(
            port: port,
            pageURLContains: filter,
            attempts: config.type == "dev-server" ? 120 : 20
        )
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
        // Set before enabling: V8 replays every already-parsed script the
        // moment `Debugger.enable` lands, and for an attach that is all of
        // them. Registering the breakpoints afterwards meant those replayed
        // events arrived with nothing to bind and were all discarded — so a
        // breakpoint in a bundled file never resolved.
        pendingSourceMappedBreakpoints = breakpoints

        _ = try await cdp.send("Debugger.enable")
        _ = try? await cdp.send("Runtime.enable")
        _ = try? await cdp.send("Console.enable")

        // 5. Set breakpoints.
        let isChrome = isBrowserType(config.type)
        for (filePath, lines) in breakpoints {
            // Node reports every script by its real path, so a breakpoint
            // registered against a path that passes through a symlink binds
            // to nothing and is silently ignored (`locations: []`). That is
            // /tmp vs /private/tmp on macOS, and any symlinked checkout.
            // Both spellings are registered when they differ, so the
            // breakpoint lands whichever way the runtime names the file.
            let resolvedPath = Self.realPath(of: filePath)
            let pathsToBind = resolvedPath == filePath ? [filePath] : [resolvedPath, filePath]
            for line in lines {
                if isChrome {
                    let filename = (URL(fileURLWithPath: filePath).lastPathComponent)
                        .replacingOccurrences(of: ".", with: "\\.")
                    // cdpJSON keeps [String: Any] inside the DebugService actor — only Data crosses.
                    _ = try? await cdp.send("Debugger.setBreakpointByUrl",
                        paramsJSON: cdpJSON(["urlRegex": ".*\(filename).*", "lineNumber": line - 1]))
                } else {
                    for path in pathsToBind {
                        _ = try? await cdp.send("Debugger.setBreakpointByUrl",
                            paramsJSON: cdpJSON(["url": "file://\(path)", "lineNumber": line - 1]))
                    }
                    // A bundler names its modules after the original file
                    // without using a file:// URL —
                    // `webpack-internal:///(rsc)/./src/hooks/use-client.ts`
                    // is the same file the user is editing. Matching the
                    // path's tail binds those too, which is what makes a
                    // breakpoint work in a dev server at all.
                    if let pattern = Self.urlRegex(for: filePath, workspaceURL: workspaceURL) {
                        _ = try? await cdp.send("Debugger.setBreakpointByUrl",
                            paramsJSON: cdpJSON(["urlRegex": pattern, "lineNumber": line - 1]))
                    }
                }
            }
        }

        // 6. Node pauses immediately with --inspect-brk; release it into user
        //    code. That entry pause is an artefact of how the process is
        //    started, not something the user asked for, so unless the config
        //    sets stopOnEntry it is swallowed rather than reported as a stop
        //    at whatever line happens to be first.
        breakpointsRegistered = true

        // Next.js renders with Turbopack by default, in a child process that
        // carries no inspector — so an attach reaches the framework but
        // never the app, and no breakpoint can bind. Say so rather than
        // leaving the session looking healthy but inert.
        if !breakpoints.isEmpty {
            let session = cdpClient
            Task { [weak self] in
                let clock = ContinuousClock()
                try? await clock.sleep(until: clock.now.advanced(by: .seconds(8)))
                guard let self, await self.cdpClient === session else { return }
                await self.reportIfNoBreakpointBound()
            }
        }

        if !isBrowserType(config.type), config.type != "dev-server" {
            _ = try? await cdp.send("Runtime.runIfWaitingForDebugger")
            // `runIfWaitingForDebugger` clears the waiting state but does not
            // lift the `--inspect-brk` halt: without an explicit resume the
            // process sits on its first line forever. Only resume a halt that
            // has actually been reported, or the request arrives before there
            // is anything to release and is simply rejected.
            if !config.stopOnEntry, entryPauseAwaitingResume {
                entryPauseAwaitingResume = false
                _ = try? await cdp.send("Debugger.resume")
            }
        }

        cbStateChange?(.running)
    }

    /// Waits for the adapter's `initialized` event. Bounded: an adapter that
    /// never sends one still gets its breakpoints, which is better than
    /// hanging the session.
    private func awaitDAPInitialized(timeout: Duration = .seconds(5)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !dapInitialized, clock.now < deadline {
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(20)))
        }
    }

    /// Arguments the adapter binary itself needs. `@vscode/js-debug` is a
    /// script run by Node, so the script path has to be passed along —
    /// launching the Node binary bare would just open a REPL that never
    /// speaks DAP.
    private func adapterArguments(for config: LaunchConfig) -> [String] {
        switch config.type {
        case "node", "typescript", "pwa-node":
            if let script = Self.jsDebugServerPath() { return [script, String(config.debugPort ?? 8123)] }
            return []
        case "python":
            return ["-m", "debugpy.adapter"]
        default:
            return []
        }
    }

    // MARK: - Controls

    func continueExecution(threadId: Int = 1) async throws {
        if let sfcc = sfccSession { try await sfcc.resume(); return }
        let threadId = lastStoppedThreadId ?? threadId
        if isCDP { _ = try await cdpClient?.send("Debugger.resume")
        } else    { _ = try await dapClient.request("continue", args: ["threadId": threadId]) }
    }

    func stepOver(threadId: Int = 1) async throws {
        let threadId = lastStoppedThreadId ?? threadId
        if let sfcc = sfccSession { try await sfcc.step(.over); return }
        if isCDP { _ = try await cdpClient?.send("Debugger.stepOver")
        } else    { _ = try await dapClient.request("next", args: ["threadId": threadId]) }
    }

    func stepIn(threadId: Int = 1) async throws {
        let threadId = lastStoppedThreadId ?? threadId
        if let sfcc = sfccSession { try await sfcc.step(.into); return }
        if isCDP { _ = try await cdpClient?.send("Debugger.stepInto")
        } else    { _ = try await dapClient.request("stepIn", args: ["threadId": threadId]) }
    }

    func stepOut(threadId: Int = 1) async throws {
        let threadId = lastStoppedThreadId ?? threadId
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
        let threadId = lastStoppedThreadId ?? threadId
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
            dapInitialized = true
            cbStateChange?(.running)
        case "stopped":
            let reason   = body["reason"]   as? String ?? "pause"
            let threadId = body["threadId"] as? Int    ?? lastStoppedThreadId ?? 1
            lastStoppedThreadId = threadId
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
            let pauseReason = params["reason"] as? String ?? "breakpoint"
            // V8 names the `--inspect-brk` halt "Break on start"; a real
            // breakpoint arrives as "other". Keying on the reason alone is
            // deterministic — testing "have we resumed yet" raced with the
            // event stream and swallowed the first genuine hit instead.
            if !stopOnEntryRequested, pauseReason == "Break on start" {
                if breakpointsRegistered {
                    let client = cdpClient
                    Task { _ = try? await client?.send("Debugger.resume") }
                } else {
                    // Arrived before the breakpoints were in place —
                    // releasing it now would let the script run to
                    // completion. `launchCDP` resumes it instead.
                    entryPauseAwaitingResume = true
                }
                return
            }
            let reason = pauseReason
            let top    = frames.first
            let loc    = top?["location"] as? [String: Any]
            let rawLine = (loc?["lineNumber"] as? Int ?? 0) + 1
            let url    = top?["url"] as? String ?? ""
            let scriptId = loc?["scriptId"] as? String
            let (path, line) = originalLocation(
                scriptId: scriptId,
                url: url,
                generatedLine: rawLine,
                generatedColumn: loc?["columnNumber"] as? Int ?? 0
            )
            cbStateChange?(.paused(reason: reason))
            cbStopped?(DebugStop(reason: reason, threadId: 0, filePath: path, line: line))

        case "Debugger.scriptParsed":
            await bindBreakpointsThroughSourceMap(params)

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

    /// Places pending breakpoints inside a freshly parsed generated script,
    /// translating each original line through the script's source map.
    ///
    /// This is what makes a breakpoint in a Next.js, Vite or tsc project
    /// bind at all: the file the user set it in is never the file the
    /// runtime executes.
    private func bindBreakpointsThroughSourceMap(_ params: [String: Any]) async {
        if let id = params["scriptId"] as? String { scriptURLs[id] = params["url"] as? String ?? "" }
        guard !pendingSourceMappedBreakpoints.isEmpty,
              let cdp = cdpClient,
              let scriptId = params["scriptId"] as? String,
              let sourceMapURL = params["sourceMapURL"] as? String,
              !sourceMapURL.isEmpty else { return }

        let scriptURL = params["url"] as? String ?? ""
        guard let map = await sourceMap(at: sourceMapURL, relativeTo: scriptURL) else { return }
        scriptMaps[scriptId] = map
        scriptURLs[scriptId] = scriptURL

        for (filePath, lines) in pendingSourceMappedBreakpoints.sorted(by: { $0.key < $1.key }) {
            guard map.sourceIndex(matching: filePath) != nil else { continue }
            for line in lines.sorted() {
                guard let generatedLine = map.generatedLine(forSourceMatching: filePath, originalLine: line) else { continue }
                let key = "\(scriptId):\(generatedLine)"
                guard boundSourceMappedLines.insert(key).inserted else { continue }
                _ = try? await cdp.send("Debugger.setBreakpoint", paramsJSON: cdpJSON([
                    "location": ["scriptId": scriptId, "lineNumber": generatedLine - 1],
                ]))
                anyBreakpointBound = true
                cbOutput?("[Athena] Breakpoint bound: \((filePath as NSString).lastPathComponent):\(line) → generated line \(generatedLine)\n")
            }
        }
    }

    /// Fetches and caches a source map. Handles the three forms a runtime
    /// reports: inline `data:` payload, an absolute URL, and a name relative
    /// to the script that referenced it.
    private func sourceMap(at sourceMapURL: String, relativeTo scriptURL: String) async -> SourceMap? {
        if let cached = sourceMapCache[sourceMapURL] { return cached }

        var data: Data?
        if sourceMapURL.hasPrefix("data:") {
            if let comma = sourceMapURL.firstIndex(of: ",") {
                let payload = String(sourceMapURL[sourceMapURL.index(after: comma)...])
                data = sourceMapURL[..<comma].contains("base64")
                    ? Data(base64Encoded: payload)
                    : payload.removingPercentEncoding.map { Data($0.utf8) }
            }
        } else if let absolute = Self.resolveMapURL(sourceMapURL, relativeTo: scriptURL) {
            if absolute.isFileURL {
                data = try? Data(contentsOf: absolute)
            } else {
                data = try? await URLSession.shared.data(from: absolute).0
            }
        }

        guard let data, let map = SourceMap.parse(data) else { return nil }
        sourceMapCache[sourceMapURL] = map
        return map
    }

    /// Resolves a `sourceMappingURL` against the script that declared it.
    nonisolated static func resolveMapURL(_ sourceMapURL: String, relativeTo scriptURL: String) -> URL? {
        if let absolute = URL(string: sourceMapURL), absolute.scheme != nil { return absolute }
        guard let base = URL(string: scriptURL) else { return nil }
        return URL(string: sourceMapURL, relativeTo: base)?.absoluteURL
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

    private func cdpProcessEnded(exitStatus: Int32? = nil) async {
        // Say why the session ended. A program that exits before any
        // breakpoint runs — the usual outcome of pointing "current file" at
        // a module whose functions nothing calls — otherwise just looked
        // like the debugger doing nothing at all.
        if let exitStatus {
            let everPaused = lastStoppedThreadId != nil || !cdpFrames.isEmpty
            if exitStatus == 0 && !everPaused {
                cbOutput?("[Athena] The program ran to completion without hitting a breakpoint. Nothing called the code you marked, or this file only defines things other code imports.\n")
            } else if exitStatus != 0 {
                cbOutput?("[Athena] The program exited with code \(exitStatus). See the output above for the reason.\n")
            } else {
                cbOutput?("[Athena] Debug session ended.\n")
            }
        }
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
        guard Self.jsDebugServerPath() != nil else {
            throw DAPError.adapterNotFound("@vscode/js-debug not found. Run: npm install -g @vscode/js-debug — or use a \"node-cdp\" config, which needs no adapter.")
        }
        guard let node = findNodeBinary() else {
            throw DAPError.adapterNotFound("Node.js not found on PATH.")
        }
        return node
    }

    /// Whether any breakpoint has resolved in this session.
    private var anyBreakpointBound = false

    private func reportIfNoBreakpointBound() {
        guard !anyBreakpointBound, lastStoppedThreadId == nil else { return }
        cbOutput?("""
            [Athena] No breakpoint has bound yet. If this is a Next.js dev server,             note that Turbopack (the default) renders your app in a separate process             with no inspector attached; run it with --webpack to debug server-side code.

            """)
    }

    /// Where a paused frame is in the user's own files.
    ///
    /// A dev server stops inside generated code named
    /// `webpack-internal:///(rsc)/./src/hooks/use-client.ts` at a line that
    /// includes the bundler's preamble. Without translating both, the editor
    /// has no file to open and would mark the wrong line.
    private func originalLocation(
        scriptId: String?,
        url: String,
        generatedLine: Int,
        generatedColumn: Int
    ) -> (String?, Int) {
        if let scriptId, let map = scriptMaps[scriptId],
           let position = map.originalPosition(generatedLine: generatedLine, generatedColumn: generatedColumn),
           let local = localPath(forModuleNamed: position.source) {
            return (local, position.line)
        }
        return (localPath(forModuleNamed: url), generatedLine)
    }

    /// Resolves a script or source name to a file on disk: a `file://` URL
    /// directly, otherwise the longest tail of the name that exists inside
    /// the open folder.
    private func localPath(forModuleNamed name: String) -> String? {
        if name.hasPrefix("file://") {
            let raw = String(name.dropFirst("file://".count))
            return raw.removingPercentEncoding ?? raw
        }
        guard let root = currentWorkspaceURL else { return nil }
        let cleaned = name.components(separatedBy: "?").first ?? name
        let parts = cleaned.split(separator: "/").filter { $0 != "." && $0 != ".." && !$0.hasPrefix("(") }
        guard !parts.isEmpty else { return nil }
        for start in parts.indices {
            let candidate = root.appendingPathComponent(parts[start...].joined(separator: "/")).path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// A pattern matching every URL a bundler might give this file.
    ///
    /// Anchored at the end on the workspace-relative path, so
    /// `src/hooks/use-client.ts` matches `webpack-internal:///(rsc)/./src/hooks/use-client.ts`
    /// and `file:///…/src/hooks/use-client.ts` while staying specific enough
    /// not to collide with a same-named file in another folder.
    nonisolated static func urlRegex(for filePath: String, workspaceURL: URL?) -> String? {
        var relative = filePath
        if let root = workspaceURL?.standardizedFileURL.path, filePath.hasPrefix(root + "/") {
            relative = String(filePath.dropFirst(root.count + 1))
        } else {
            // No workspace: the last two components are specific enough.
            let parts = filePath.split(separator: "/")
            relative = parts.suffix(2).joined(separator: "/")
        }
        guard !relative.isEmpty else { return nil }
        let escaped = relative.map { character -> String in
            ".^$*+?()[]{}|\\/".contains(character) ? "\\\(character)" : String(character)
        }.joined()
        return ".*" + escaped + "$"
    }

    /// The true on-disk path, following every symlink.
    ///
    /// `URL.resolvingSymlinksInPath()` is not a substitute: Foundation
    /// deliberately rewrites `/private/var/…` to `/var/…`, the opposite of
    /// what the runtime reports, so breakpoints registered from it never
    /// match the script V8 has loaded.
    nonisolated static func realPath(of path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    /// Locates Node, including under a version manager.
    ///
    /// Deliberately no subprocess: asking an interactive login shell
    /// (`zsh -i -l -c`) for the PATH hangs whenever no terminal is attached,
    /// which would freeze the debugger rather than fail to find Node. The
    /// version managers all install to predictable locations, so look there.
    private func findNodeBinary() -> String? {
        if let cached = cachedNodePath { return cached }
        let home = NSHomeDirectory()
        var candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]

        // nvm keeps one directory per installed version; prefer the newest,
        // compared numerically so v26 beats v9.
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            candidates += versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(nvmRoot)/\($0)/bin/node" }
        }
        candidates += ["\(home)/.volta/bin/node", "\(home)/.asdf/shims/node", "\(home)/.local/bin/node"]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            cachedNodePath = path
            return path
        }
        return nil
    }

    /// `@vscode/js-debug`'s DAP server script, when the user has it installed.
    nonisolated static func jsDebugServerPath() -> String? {
        let candidates = [
            "/usr/local/lib/node_modules/@vscode/js-debug/src/dapDebugServer.js",
            "/opt/homebrew/lib/node_modules/@vscode/js-debug/src/dapDebugServer.js",
            "/usr/lib/node_modules/@vscode/js-debug/src/dapDebugServer.js",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Expands the launch-config variables VS Code defines.
    ///
    /// `${file}` was never substituted, so the built-in "Debug Node.js
    /// (current file)" config asked the runtime to execute a file literally
    /// named `${file}`.
    private func resolveVariable(_ value: String, workspaceURL: URL?) -> String {
        Self.expand(value, workspaceURL: workspaceURL, fileURL: currentFileURL)
    }

    nonisolated static func expand(_ value: String, workspaceURL: URL?, fileURL: URL?) -> String {
        var result = value
        if let ws = workspaceURL {
            result = result.replacingOccurrences(of: "${workspaceFolder}", with: ws.path)
            result = result.replacingOccurrences(of: "${workspaceFolderBasename}", with: ws.lastPathComponent)
        }
        if let file = fileURL {
            result = result.replacingOccurrences(of: "${file}", with: file.path)
            result = result.replacingOccurrences(of: "${fileBasename}", with: file.lastPathComponent)
            result = result.replacingOccurrences(of: "${fileDirname}", with: file.deletingLastPathComponent().path)
            result = result.replacingOccurrences(
                of: "${fileBasenameNoExtension}",
                with: file.deletingPathExtension().lastPathComponent
            )
        }
        return result
    }

    // MARK: - Type helpers

    private func isCDPType(_ type: String) -> Bool {
        switch type {
        case "node-cdp", "chrome", "nextjs", "dev-server": return true
        default: return false
        }
    }

    /// The package manager a project actually uses, from its lockfile.
    nonisolated static func packageManager(for workspaceURL: URL) -> String {
        let lockfiles = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun")]
        for (lockfile, manager) in lockfiles
        where FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent(lockfile).path) {
            return manager
        }
        return "npm"
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
