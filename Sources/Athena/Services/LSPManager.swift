// LSPManager.swift
// Athena — manages language-server process lifecycle and JSON-RPC 2.0 communication.
// Swift 6, strict concurrency.

import Foundation

// MARK: - LSP transport types

/// One running language-server process with its stdio handles and in-flight
/// pending requests keyed by their JSON-RPC id.
private struct LSPServerProcess {
    var process: Process
    var stdinHandle: FileHandle
    var stdoutHandle: FileHandle
    var nextId: Int = 1
    /// Continuations waiting for a specific response id.
    var pending: [Int: CheckedContinuation<Data, Error>] = [:]
}

// MARK: - LSPManager

actor LSPManager {

    // MARK: State

    private var servers: [Language: LSPServerProcess] = [:]
    /// Continuation feeding `diagnosticsStream()`; nil until a consumer subscribes.
    private var diagnosticsContinuation: AsyncStream<(URL, [Diagnostic])>.Continuation?
    /// Cached result of resolving the user's real login-shell `$PATH`; see
    /// `resolvedUserPath()`. `nil` until first resolved.
    private var cachedUserPath: String?
    /// Languages currently mid-`startServer`, i.e. past the first `await` but
    /// before `servers[language]` is set. `openFile` fires `startServer` from
    /// an unstructured `Task` per opened file, so restoring several same-
    /// language tabs on launch calls it concurrently — see `startServer`.
    private var startingLanguages: Set<Language> = []

    // MARK: - Public API

    /// Starts a language server for `language` in `workspaceURL` if one is not
    /// already running.  Silently returns when no server executable can be found.
    func startServer(for language: Language, workspaceURL: URL) async throws {
        // Claiming `language` here, synchronously, before the first `await`,
        // matters: `executablePath` used to be synchronous, so this whole
        // prefix ran atomically on the actor with no suspension point before
        // `servers[language]` was set, and a concurrent second call's
        // `servers[language] == nil` check would always see the first call's
        // write. Making `executablePath` async (to resolve the user's real
        // `$PATH`) introduced a real suspension point *before* that write —
        // without this guard, two concurrent calls for the same language (as
        // above) could both pass the nil check, each spawn its own server
        // process, and the second's `servers[language] = server` would
        // silently overwrite the first's, orphaning its `initialize` request
        // continuation forever (observed as a genuine "leaked continuation"
        // runtime warning once the PATH fix made servers actually start).
        guard servers[language] == nil, !startingLanguages.contains(language) else { return }
        startingLanguages.insert(language)
        defer { startingLanguages.remove(language) }

        guard let exec = await executablePath(for: language) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exec)
        process.arguments = ["--stdio"]

        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput  = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError  = Pipe() // discard stderr

        // Without this, a crashed/killed server (or one that never replies to
        // `shutdown`) leaves `servers[language]` pointing at a dead process
        // forever: every in-flight request's continuation leaks (never
        // resumes — the caller hangs), and every future `sendRequest` call
        // writes to a closed pipe and then hangs the same way waiting for a
        // reply that will never come. `handleServerTermination` drains
        // `pending` with an error and clears the entry so callers fail fast
        // instead of hanging, and a later `startServer` can restart cleanly.
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { await self?.handleServerTermination(for: language, process: terminatedProcess) }
        }

        let server = LSPServerProcess(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stdoutHandle: stdoutPipe.fileHandleForReading
        )
        servers[language] = server

        // Send initialize
        let initParams: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": workspaceURL.absoluteString,
            "capabilities": [
                "textDocument": [
                    // `snippetSupport: true` tells the server it's safe to send
                    // `$1`/`${1:placeholder}`/`$0`-style `insertText` (LSP's
                    // `insertTextFormat: Snippet`) — `EditorView.Coordinator.insertCompletion`
                    // expands that via `SnippetEngine` the same way it does for
                    // Drizzle's own authored snippets (plan.md item 16, "B5").
                    "completion": ["dynamicRegistration": false, "completionItem": ["snippetSupport": true]],
                    "hover":      ["dynamicRegistration": false],
                ],
            ],
        ]

        _ = try await sendRequest(method: "initialize", params: initParams, language: language)

        // Send initialized notification (no id, no response expected)
        sendNotification(method: "initialized", params: [:], language: language)

        // Start background reader
        startReadingLoop(for: language, process: process, stdoutHandle: server.stdoutHandle)
    }

    /// Shuts down and terminates the language server for `language`.
    func stopServer(for language: Language) async {
        guard servers[language] != nil else { return }

        // Best-effort graceful shutdown
        _ = try? await sendRequest(method: "shutdown", params: [:], language: language)
        sendNotification(method: "exit", params: [:], language: language)

        servers[language]?.process.terminate()
        servers[language] = nil
    }

    /// Cleans up after `process` (the language server for `language`) exits —
    /// whether it crashed, was killed externally, or was terminated by
    /// `stopServer` itself — draining any still-pending request
    /// continuations with an error instead of leaking them, so a caller
    /// awaiting `hover`/`complete`/`rename`/etc. never hangs forever on a
    /// server that will never reply. Only touches `servers[language]` if it
    /// still refers to this exact process — guards against clobbering a
    /// newer server already restarted for the same language in the window
    /// between this process dying and this handler running on the actor.
    private func handleServerTermination(for language: Language, process: Process) {
        guard let server = servers[language], server.process === process else { return }
        for continuation in server.pending.values {
            continuation.resume(throwing: LSPError.serverTerminated(language))
        }
        servers[language] = nil
    }

    /// Requests completions at the given position.  Returns an empty array when
    /// no server is running or the response cannot be parsed.
    func complete(fileURL: URL, line: Int, character: Int) async throws -> [CompletionItem] {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return [] }

        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "position": ["line": line, "character": character],
        ]

        guard let data = try? await sendRequest(method: "textDocument/completion", params: params, language: language) else {
            return []
        }

        return parseCompletions(from: data)
    }

    /// Requests hover information at the given position.  Returns `nil` when no
    /// server is running or the response contains no useful content.
    func hover(fileURL: URL, line: Int, character: Int) async throws -> String? {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return nil }

        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "position": ["line": line, "character": character],
        ]

        guard let data = try? await sendRequest(method: "textDocument/hover", params: params, language: language) else {
            return nil
        }

        return parseHover(from: data)
    }

    /// Requests the definition location for the symbol at the given position.
    /// Returns `nil` when no server is running, the server has no definition
    /// for this position, or the response cannot be parsed. Handles a
    /// response `result` that is a single `Location`, an array of `Location`,
    /// or an array of `LocationLink` (whose target is nested under
    /// `targetUri`/`targetRange`) — taking the first entry when several come
    /// back.
    func definition(fileURL: URL, line: Int, character: Int) async throws -> DefinitionLocation? {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return nil }

        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "position": ["line": line, "character": character],
        ]

        guard let data = try? await sendRequest(method: "textDocument/definition", params: params, language: language) else {
            return nil
        }

        return parseDefinition(from: data)
    }

    /// Requests every reference to the symbol at the given position via
    /// `textDocument/references`. `includeDeclaration` mirrors the LSP
    /// request field of the same name (VS Code's "Find All References"
    /// includes the declaration itself by default). Returns an empty array
    /// when no server is running or the response contains no locations.
    func references(
        fileURL: URL,
        line: Int,
        character: Int,
        includeDeclaration: Bool = true
    ) async throws -> [DefinitionLocation] {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return [] }

        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "position": ["line": line, "character": character],
            "context": ["includeDeclaration": includeDeclaration],
        ]

        guard let data = try? await sendRequest(method: "textDocument/references", params: params, language: language) else {
            return []
        }

        return parseReferences(from: data)
    }

    /// Requests a `textDocument/rename` workspace edit for the symbol at the
    /// given position, renaming it to `newName`. Parses the response's
    /// `WorkspaceEdit` (`{changes: {uri: TextEdit[]}}`, or the alternate
    /// `documentChanges` form) into a per-file list of `LSPTextEdit`s —
    /// callers apply each file's edits with `applyLSPTextEdits`, the same
    /// pure function `formatting(fileURL:content:tabSize:insertSpaces:)`
    /// already uses, so the offset-conversion logic isn't duplicated.
    /// Returns an empty dictionary when no server is running, the server has
    /// nothing to rename, or the response can't be parsed.
    func rename(
        fileURL: URL,
        line: Int,
        character: Int,
        newName: String
    ) async throws -> [URL: [LSPTextEdit]] {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return [:] }

        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "position": ["line": line, "character": character],
            "newName": newName,
        ]

        guard let data = try? await sendRequest(method: "textDocument/rename", params: params, language: language) else {
            return [:]
        }

        return parseWorkspaceEdit(from: data)
    }

    /// Requests document formatting from the running language server for
    /// `fileURL`'s language and applies the returned `TextEdit[]` to
    /// `content`, returning the fully-formatted text. Returns `nil` when no
    /// server is running, the server returns no edits (nothing to change),
    /// or the response can't be parsed — callers should fall back to another
    /// formatter (e.g. Prettier) in any of those cases.
    func formatting(
        fileURL: URL,
        content: String,
        tabSize: Int,
        insertSpaces: Bool
    ) async throws -> String? {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return nil }

        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "options": [
                "tabSize": tabSize,
                "insertSpaces": insertSpaces,
            ],
        ]

        guard let data = try? await sendRequest(method: "textDocument/formatting", params: params, language: language) else {
            return nil
        }

        return parseFormatting(from: data, originalContent: content)
    }

    /// Requests `textDocument/documentSymbol` for `fileURL` and normalizes the
    /// response into a `[DocumentSymbol]` tree — feeds Go to Symbol (⇧⌘O),
    /// the Outline sidebar panel, and the breadcrumbs bar (all reading from
    /// `AppState.documentSymbols`, so this is the only request site). Per the
    /// LSP spec `result` may be an array of hierarchical `DocumentSymbol`
    /// (`{name, kind, range, selectionRange, children?}`) or the older, flat
    /// `SymbolInformation` (`{name, kind, location: {uri, range}}`, never
    /// nested) — servers don't distinguish which shape they'll send in the
    /// response itself, so both are parsed directly off the JSON in
    /// `parseDocumentSymbol`. Returns an empty array when no server is
    /// running or the response can't be parsed.
    func documentSymbols(fileURL: URL) async throws -> [DocumentSymbol] {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return [] }

        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
        ]

        guard let data = try? await sendRequest(method: "textDocument/documentSymbol", params: params, language: language) else {
            return []
        }

        return parseDocumentSymbols(from: data)
    }

    /// Notifies the language server that a file's content has changed.
    func didChange(fileURL: URL, content: String) async {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return }

        let params: [String: Any] = [
            "textDocument": [
                "uri": fileURL.absoluteString,
                "version": Int.random(in: 1 ..< Int.max),
            ],
            "contentChanges": [
                ["text": content],
            ],
        ]
        sendNotification(method: "textDocument/didChange", params: params, language: language)
    }

    /// Notifies the language server that a file has been opened in the editor.
    func didOpen(fileURL: URL, content: String) async {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return }

        let params: [String: Any] = [
            "textDocument": [
                "uri":        fileURL.absoluteString,
                "languageId": language.rawValue,
                "version":    1,
                "text":       content,
            ],
        ]
        sendNotification(method: "textDocument/didOpen", params: params, language: language)
    }

    /// Notifies the language server that a file has been closed in the editor.
    func didClose(fileURL: URL) async {
        let language = Language.detect(from: fileURL)
        guard servers[language] != nil else { return }

        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
        ]
        sendNotification(method: "textDocument/didClose", params: params, language: language)
    }

    /// Shuts down every currently running language server. Used when tearing
    /// down a workspace (opening another folder, or closing the current one).
    func stopAllServers() async {
        for language in Array(servers.keys) {
            await stopServer(for: language)
        }
    }

    /// Returns a stream of `(fileURL, diagnostics)` pairs, yielded every time a
    /// running server pushes a `textDocument/publishDiagnostics` notification.
    /// Only one subscriber is supported at a time (the latest one wins), which
    /// matches how `AppState` consumes it — a single long-lived Task at launch.
    ///
    /// Builds the stream via `AsyncStream.makeStream()` rather than the
    /// `AsyncStream { continuation in ... }` initializer so the continuation
    /// is stored as a plain, synchronous actor-isolated assignment. The
    /// closure-based initializer requires hopping through a nested `Task` to
    /// touch actor state, which races the server's own notification handler:
    /// a `publishDiagnostics` notification arriving before that nested Task
    /// is scheduled would find `diagnosticsContinuation` still `nil` and be
    /// silently dropped.
    func diagnosticsStream() -> AsyncStream<(URL, [Diagnostic])> {
        let (stream, continuation) = AsyncStream<(URL, [Diagnostic])>.makeStream()
        diagnosticsContinuation = continuation
        return stream
    }

    // MARK: - Executable discovery

    /// Fixed install locations are checked first (cheap, no process spawn),
    /// then the user's real login-shell `$PATH` (see `resolvedUserPath()`) —
    /// this is what makes a version-manager-installed server (e.g.
    /// `typescript-language-server` via nvm, living under
    /// `~/.nvm/versions/node/<version>/bin`) discoverable at all: a
    /// GUI-launched app only inherits a minimal `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), which none of nvm/pyenv/rbenv ever
    /// touch — they only extend `PATH` via shell rc files.
    private func executablePath(for language: Language) async -> String? {
        switch language {
        case .typescript, .javascript:
            return await firstExecutable(named: "typescript-language-server") ?? firstExecutable(at: [
                "/usr/local/bin/typescript-language-server",
                "/opt/homebrew/bin/typescript-language-server",
            ])
        case .python:
            return await firstExecutable(named: "pylsp") ?? firstExecutable(at: ["/usr/local/bin/pylsp"])
        case .rust:
            return await firstExecutable(named: "rust-analyzer") ?? firstExecutable(at: [
                "/usr/local/bin/rust-analyzer",
                (NSHomeDirectory() as NSString).appendingPathComponent(".cargo/bin/rust-analyzer"),
            ])
        case .go:
            return await firstExecutable(named: "gopls") ?? firstExecutable(at: [
                "/usr/local/bin/gopls",
                "/opt/homebrew/bin/gopls",
            ])
        case .swift:
            if let path = firstExecutable(at: ["/usr/bin/sourcekit-lsp"]) {
                return path
            }
            // Fall back to xcrun
            if let xcrun = firstExecutable(at: ["/usr/bin/xcrun"]) {
                return xcrun  // caller would need to pass ["sourcekit-lsp"] as args; handled below
            }
            return nil
        default:
            return nil
        }
    }

    private func firstExecutable(at paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Searches every directory in the user's resolved `$PATH` for an
    /// executable named `name`, in order (first match wins, matching shell
    /// `PATH` lookup semantics).
    private func firstExecutable(named name: String) async -> String? {
        let path = await resolvedUserPath()
        for directory in path.split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Resolves (and caches for the rest of the app's run) `$PATH` by asking
    /// the user's login shell for it directly, rather than trusting whatever
    /// minimal environment this GUI process inherited. `-i -l` sources both
    /// login startup files (`~/.zprofile`, where Homebrew's `shellenv` line
    /// typically lives) and interactive ones (`~/.zshrc`, where nvm/pyenv/
    /// rbenv-style shims are installed) — omitting either misses a whole
    /// class of real-world installs. The echoed value is wrapped in unique
    /// markers on their own line because noisy shell startup files (MOTD
    /// banners, prompt-framework output) can print to stdout before it.
    private func resolvedUserPath() async -> String {
        if let cachedUserPath { return cachedUserPath }

        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let resolved: String? = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-i", "-l", "-c", #"echo "__ATHENA_PATH_START__"; echo "$PATH"; echo "__ATHENA_PATH_END__""#]
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe() // discard rc-file noise

            process.terminationHandler = { _ in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let lines = String(data: data, encoding: .utf8)?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
                if let startIndex = lines.firstIndex(of: "__ATHENA_PATH_START__"),
                   startIndex + 1 < lines.count {
                    continuation.resume(returning: String(lines[startIndex + 1]))
                } else {
                    continuation.resume(returning: nil)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }

        let path = (resolved?.isEmpty == false) ? resolved! : fallback
        cachedUserPath = path
        return path
    }

    // MARK: - JSON-RPC message construction

    /// Builds a JSON-RPC 2.0 request object and returns it as `Data` including
    /// the `Content-Length` LSP header framing.
    private func makeRequest(id: Int, method: String, params: [String: Any]) -> Data {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if !params.isEmpty { obj["params"] = params }
        return frame(obj)
    }

    /// Builds a JSON-RPC 2.0 notification (no `id`) and returns framed `Data`.
    private func makeNotification(method: String, params: [String: Any]) -> Data {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if !params.isEmpty { obj["params"] = params }
        return frame(obj)
    }

    /// Prepends `Content-Length: N\r\n\r\n` and returns the framed payload.
    private func frame(_ object: [String: Any]) -> Data {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return Data() }
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var data = header.data(using: .utf8)!
        data.append(body)
        return data
    }

    /// Writes framed data to the server's stdin handle.
    private func sendMessage(_ data: Data, to server: inout LSPServerProcess) {
        try? server.stdinHandle.write(contentsOf: data)
    }

    // MARK: - Request / notification dispatch

    @discardableResult
    private func sendRequest(
        method: String,
        params: [String: Any],
        language: Language
    ) async throws -> Data {
        guard var server = servers[language] else {
            throw LSPError.serverNotRunning(language)
        }

        let id = server.nextId
        server.nextId += 1
        servers[language] = server

        return try await withCheckedThrowingContinuation { continuation in
            guard var s = servers[language] else {
                continuation.resume(throwing: LSPError.serverNotRunning(language))
                return
            }
            s.pending[id] = continuation
            servers[language] = s

            let data = makeRequest(id: id, method: method, params: params)
            sendMessage(data, to: &servers[language]!)
        }
    }

    private func sendNotification(method: String, params: [String: Any], language: Language) {
        guard servers[language] != nil else { return }
        let data = makeNotification(method: method, params: params)
        sendMessage(data, to: &servers[language]!)
    }

    // MARK: - Background response reading

    /// Starts a dedicated background `Thread` that continuously reads LSP
    /// framed messages from the server's stdout and hands each one back to
    /// the actor to fulfil pending continuations.
    ///
    /// This runs on a plain `Thread`, not a `Task` on Swift's shared
    /// cooperative thread pool, because `readFramedMessages` blocks on
    /// `FileHandle.readData(ofLength:)` — every other Process-based service
    /// in this codebase (`DAPClient`, `CDPClient`, `DebugService`'s CDP
    /// path) instead uses a non-blocking `readabilityHandler` precisely to
    /// avoid tying up a cooperative-pool worker for the process's entire
    /// lifetime. With several language servers running at once, blocking
    /// reads directly inside a `Task` could starve that shared, size-limited
    /// pool for every other actor/Task in the process; a dedicated thread
    /// blocks only itself. The thread exits naturally once `readData`
    /// returns empty — when the process dies (crash, external kill, or
    /// `stopServer`'s own `.terminate()`) its stdout write end closes and
    /// unblocks the read with EOF, exactly as it did when this loop ran
    /// inside a `Task`.
    private func startReadingLoop(for language: Language, process: Process, stdoutHandle: FileHandle) {
        // Captures `self` strongly, not weakly: LSPManager is a permanent
        // singleton owned by AppState for the app's entire lifetime (never
        // deallocated before process exit — same reasoning already applied
        // to the actor self-captures in ClaudeCLIService/ClaudeService), so
        // there's no dangling-self risk to guard against. A `weak self`
        // capture here is also what a stricter toolchain flags as "passing
        // closure as a 'sending' parameter risks causing data races" — the
        // weak reference's synthesized mutable backing storage, threaded
        // through the nested `onMessage` closure into a `Task`, reads as a
        // shared mutable capture crossing an isolation boundary. A plain
        // strong capture of an actor (inherently Sendable) sidesteps that.
        let thread = Thread { [self] in
            Self.readFramedMessages(from: stdoutHandle) { bodyData in
                Task { await self.handleIncomingMessage(bodyData, language: language, process: process) }
            }
        }
        thread.name = "LSPManager.readLoop.\(language.rawValue)"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// Parses one complete JSON-RPC message and dispatches it — resolves the
    /// matching pending continuation for a response, or hands a
    /// server-initiated notification to `handleNotification`. Only touches
    /// `servers[language]` if it still refers to `process` — guards against
    /// a stray trailing message from an old, already-replaced server
    /// generation being misdelivered to a newer one restarted for the same
    /// language (both would otherwise share the same `id` numbering, since
    /// each `LSPServerProcess.nextId` restarts at 1).
    private func handleIncomingMessage(_ bodyData: Data, language: Language, process: Process) {
        guard let server = servers[language], server.process === process else { return }
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else { return }

        if let id = json["id"] as? Int {
            // Resolve the pending continuation for a request response.
            server.pending[id]?.resume(returning: bodyData)
            servers[language]?.pending.removeValue(forKey: id)
        } else if let method = json["method"] as? String {
            // Server-initiated notification (no "id" field).
            handleNotification(method: method, params: json["params"] as? [String: Any])
        }
    }

    /// Reads LSP-framed (`"Content-Length: N\r\n\r\n"` + body) messages from
    /// `handle` until EOF — the process died or its stdout closed — invoking
    /// `onMessage` with each message's raw JSON body. Blocks the calling
    /// thread for as long as the server runs; callers must invoke this from
    /// a dedicated background `Thread`, never from Swift's cooperative pool.
    private static func readFramedMessages(from handle: FileHandle, onMessage: (Data) -> Void) {
        while true {
            guard let length = readContentLength(from: handle) else { break }
            let bodyData = handle.readData(ofLength: length)
            guard !bodyData.isEmpty else { break }
            onMessage(bodyData)
        }
    }

    /// Reads bytes from `handle` until the blank line terminating LSP headers is
    /// found, then parses and returns the `Content-Length` value.
    private static func readContentLength(from handle: FileHandle) -> Int? {
        var headerData = Data()
        // Read byte-by-byte until we see \r\n\r\n
        while true {
            let byte = handle.readData(ofLength: 1)
            guard !byte.isEmpty else { return nil }
            headerData.append(byte)
            if headerData.hasSuffix(Data([0x0d, 0x0a, 0x0d, 0x0a])) { break }
            if headerData.count > 4096 { return nil } // sanity limit
        }
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        for line in header.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    // MARK: - Server-initiated notifications

    /// Dispatches a JSON-RPC notification pushed by the server (no matching
    /// pending request). Currently only `textDocument/publishDiagnostics` is
    /// handled; anything else is silently ignored.
    private func handleNotification(method: String, params: [String: Any]?) {
        guard method == "textDocument/publishDiagnostics", let params else { return }
        parseDiagnostics(from: params)
    }

    /// Parses a `publishDiagnostics` notification's `params` object and yields
    /// the resulting `[Diagnostic]` (keyed by file URL) to `diagnosticsStream()`.
    private func parseDiagnostics(from params: [String: Any]) {
        guard
            let uriString = params["uri"] as? String,
            let url = URL(string: uriString)
        else { return }

        let rawDiagnostics = params["diagnostics"] as? [[String: Any]] ?? []

        let diagnostics: [Diagnostic] = rawDiagnostics.compactMap { entry in
            guard
                let range      = entry["range"] as? [String: Any],
                let start      = range["start"] as? [String: Any],
                let line       = start["line"] as? Int,
                let character  = start["character"] as? Int,
                let message    = entry["message"] as? String
            else { return nil }

            // LSP positions are 0-based; the rest of the app (gutter, cursor,
            // breakpoints) uses 1-based line/column.
            return Diagnostic(
                fileURL:  url,
                line:     line + 1,
                column:   character + 1,
                message:  message,
                severity: diagnosticSeverity(from: entry["severity"] as? Int)
            )
        }

        diagnosticsContinuation?.yield((url, diagnostics))
    }

    /// Maps the LSP `DiagnosticSeverity` integer (1=Error … 4=Hint) to our
    /// domain type. Servers that omit `severity` default to `.error`, per spec.
    private func diagnosticSeverity(from value: Int?) -> DiagnosticSeverity {
        switch value {
        case 2:  return .warning
        case 3:  return .information
        case 4:  return .hint
        default: return .error
        }
    }

    // MARK: - Response parsing

    private func parseCompletions(from data: Data) -> [CompletionItem] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"]
        else { return [] }

        // result may be a CompletionList ({ items: [...] }) or a raw array
        let items: [[String: Any]]
        if let list = result as? [String: Any], let its = list["items"] as? [[String: Any]] {
            items = its
        } else if let raw = result as? [[String: Any]] {
            items = raw
        } else {
            return []
        }

        return items.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let kind       = completionKindName(item["kind"] as? Int)
            let detail     = item["detail"] as? String
            let insertText = (item["insertText"] as? String) ?? label
            return CompletionItem(label: label, kind: kind, detail: detail, insertText: insertText)
        }
    }

    private func completionKindName(_ kind: Int?) -> String {
        switch kind {
        case 1:  return "text"
        case 2:  return "method"
        case 3:  return "function"
        case 4:  return "constructor"
        case 5:  return "field"
        case 6:  return "variable"
        case 7:  return "class"
        case 8:  return "interface"
        case 9:  return "module"
        case 10: return "property"
        case 14: return "keyword"
        case 17: return "file"
        case 18: return "reference"
        default: return "unknown"
        }
    }

    private func parseHover(from data: Data) -> String? {
        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result  = json["result"] as? [String: Any],
            let contents = result["contents"]
        else { return nil }

        if let str = contents as? String { return str.isEmpty ? nil : str }

        if let obj = contents as? [String: Any] {
            return obj["value"] as? String
        }

        if let arr = contents as? [[String: Any]] {
            return arr.compactMap { $0["value"] as? String }.joined(separator: "\n\n")
        }
        return nil
    }

    /// Parses a `textDocument/definition` response's `result`, which per the
    /// LSP spec may be a single `Location`, an array of `Location`, or (for
    /// servers that support it) an array of `LocationLink`.
    private func parseDefinition(from data: Data) -> DefinitionLocation? {
        guard
            let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"]
        else { return nil }

        if let single = result as? [String: Any] {
            return location(from: single)
        }
        if let array = result as? [[String: Any]] {
            return array.compactMap { location(from: $0) }.first
        }
        return nil
    }

    /// Parses one `Location` (`{ uri, range }`) or `LocationLink`
    /// (`{ targetUri, targetRange, ... }`) object into a `DefinitionLocation`,
    /// converting 0-based LSP positions to this app's 1-based convention.
    private func location(from entry: [String: Any]) -> DefinitionLocation? {
        guard
            let uriString = (entry["uri"] as? String) ?? (entry["targetUri"] as? String),
            let url       = URL(string: uriString),
            let range     = (entry["range"] as? [String: Any]) ?? (entry["targetRange"] as? [String: Any]),
            let start     = range["start"] as? [String: Any],
            let line      = start["line"] as? Int,
            let character = start["character"] as? Int
        else { return nil }

        return DefinitionLocation(fileURL: url, line: line + 1, character: character + 1)
    }

    /// Parses a `textDocument/references` response's `result`, which per the
    /// LSP spec is always an array of plain `Location` (never `LocationLink`,
    /// unlike `textDocument/definition`) — reuses the same `location(from:)`
    /// helper `parseDefinition` uses.
    private func parseReferences(from data: Data) -> [DefinitionLocation] {
        guard
            let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [[String: Any]]
        else { return [] }

        return result.compactMap { location(from: $0) }
    }

    /// Parses a `textDocument/rename` response's `result` — a `WorkspaceEdit`
    /// — into a per-file URL → edits map. Handles both the common `changes`
    /// form (`{uri: TextEdit[]}`) and the alternate, versioned
    /// `documentChanges` form some servers send instead, whose entries nest
    /// the URI under `textDocument.uri` and the edits under `edits`. Each
    /// file entry is cast individually (rather than casting the whole
    /// `changes`/`documentChanges` collection in one shot) so one
    /// unexpectedly-shaped entry only drops that file, not the entire
    /// workspace edit.
    private func parseWorkspaceEdit(from data: Data) -> [URL: [LSPTextEdit]] {
        guard
            let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any]
        else { return [:] }

        var edits: [URL: [LSPTextEdit]] = [:]

        if let changes = result["changes"] as? [String: Any] {
            for (uriString, rawValue) in changes {
                guard let url = URL(string: uriString), let rawEdits = rawValue as? [[String: Any]] else { continue }
                edits[url] = rawEdits.compactMap(Self.parseTextEdit)
            }
        } else if let documentChanges = result["documentChanges"] as? [Any] {
            for case let entry as [String: Any] in documentChanges {
                guard
                    let doc       = entry["textDocument"] as? [String: Any],
                    let uriString = doc["uri"] as? String,
                    let url       = URL(string: uriString),
                    let rawEdits  = entry["edits"] as? [[String: Any]]
                else { continue }
                edits[url] = rawEdits.compactMap(Self.parseTextEdit)
            }
        }

        return edits
    }

    /// Parses a `textDocument/formatting` response's `result` — an array of
    /// `TextEdit` (`{range: {start, end}, newText}`) — and applies it to
    /// `originalContent`. Returns `nil` when `result` is missing, `null`, or
    /// an empty array (server ran but reports nothing to change).
    private func parseFormatting(from data: Data, originalContent: String) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [[String: Any]],
            !result.isEmpty
        else { return nil }

        let edits = result.compactMap(Self.parseTextEdit)

        guard !edits.isEmpty else { return nil }
        return applyLSPTextEdits(edits, to: originalContent)
    }

    /// Parses a `textDocument/documentSymbol` response's `result` array,
    /// delegating each entry to `parseDocumentSymbol`. Returns an empty array
    /// when `result` is missing or not an array.
    private func parseDocumentSymbols(from data: Data) -> [DocumentSymbol] {
        guard
            let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [[String: Any]]
        else { return [] }

        return result.compactMap(Self.parseDocumentSymbol)
    }

    /// Parses one entry of a `textDocument/documentSymbol` response into a
    /// `DocumentSymbol`, handling both shapes the LSP spec allows: the
    /// hierarchical `DocumentSymbol` (`range` + `selectionRange`, optional
    /// `children`) and the older, flat `SymbolInformation` (`location: {uri,
    /// range}`, no `selectionRange`, never nested) — servers that return the
    /// latter get the symbol's full `range` reused as its `selectionRange`,
    /// so "jump to symbol" still lands somewhere inside the symbol rather
    /// than failing outright. Recurses into `children` for the hierarchical
    /// form; converts 0-based LSP positions to this app's 1-based convention,
    /// matching `LSPManager.location(from:)`.
    private static func parseDocumentSymbol(_ entry: [String: Any]) -> DocumentSymbol? {
        guard let name = entry["name"] as? String, let kind = entry["kind"] as? Int else { return nil }

        let range: [String: Any]?
        let selectionRange: [String: Any]?
        if let r = entry["range"] as? [String: Any] {
            range = r
            selectionRange = (entry["selectionRange"] as? [String: Any]) ?? r
        } else if let location = entry["location"] as? [String: Any], let r = location["range"] as? [String: Any] {
            range = r
            selectionRange = r
        } else {
            range = nil
            selectionRange = nil
        }

        guard
            let range, let selectionRange,
            let rangeStart = range["start"] as? [String: Any],
            let rangeStartLine = rangeStart["line"] as? Int,
            let rangeEnd = range["end"] as? [String: Any],
            let rangeEndLine = rangeEnd["line"] as? Int,
            let selStart = selectionRange["start"] as? [String: Any],
            let selLine = selStart["line"] as? Int,
            let selChar = selStart["character"] as? Int
        else { return nil }

        let rawChildren = entry["children"] as? [[String: Any]]
        let children = rawChildren.map { $0.compactMap(parseDocumentSymbol) }

        return DocumentSymbol(
            name: name,
            kind: kind,
            line: selLine + 1,
            character: selChar + 1,
            rangeStartLine: rangeStartLine + 1,
            rangeEndLine: rangeEndLine + 1,
            children: (children?.isEmpty ?? true) ? nil : children
        )
    }

    /// Parses one LSP `TextEdit` (`{range: {start, end}, newText}`) object
    /// into an `LSPTextEdit`. Shared by `parseFormatting`
    /// (`textDocument/formatting`) and `parseWorkspaceEdit`
    /// (`textDocument/rename`) so the JSON shape is only decoded once.
    private static func parseTextEdit(_ entry: [String: Any]) -> LSPTextEdit? {
        guard
            let range     = entry["range"] as? [String: Any],
            let start     = range["start"] as? [String: Any],
            let end       = range["end"] as? [String: Any],
            let startLine = start["line"] as? Int,
            let startChar = start["character"] as? Int,
            let endLine   = end["line"] as? Int,
            let endChar   = end["character"] as? Int,
            let newText   = entry["newText"] as? String
        else { return nil }

        return LSPTextEdit(
            startLine: startLine, startCharacter: startChar,
            endLine: endLine, endCharacter: endChar,
            newText: newText
        )
    }
}

// MARK: - Errors

private enum LSPError: Error {
    case serverNotRunning(Language)
    case serverTerminated(Language)
}

// MARK: - Data convenience

private extension Data {
    func hasSuffix(_ suffix: Data) -> Bool {
        guard count >= suffix.count else { return false }
        return self.suffix(suffix.count) == suffix
    }
}

// MARK: - TextEdit application (pure, unit-testable)

/// One `TextEdit` from an LSP response: replace the half-open range
/// `[start, end)` — expressed as 0-based `(line, character)` positions per
/// the LSP spec, `character` counted in UTF-16 code units — with `newText`.
struct LSPTextEdit: Sendable, Equatable {
    var startLine: Int
    var startCharacter: Int
    var endLine: Int
    var endCharacter: Int
    var newText: String
}

/// Applies `edits` to `content` the way a real LSP client applies a
/// `textDocument/formatting` response's `TextEdit[]`: every edit's
/// `(line, character)` position is resolved to a UTF-16 offset against the
/// *original*, unmodified `content` (LSP edits are always expressed relative
/// to the document version the server was asked to format, never relative to
/// each other), and the edits are then applied back-to-front — sorted by
/// start offset descending — so replacing one range never shifts the offsets
/// of an edit still waiting to be applied.
func applyLSPTextEdits(_ edits: [LSPTextEdit], to content: String) -> String {
    guard !edits.isEmpty else { return content }

    let ns = content as NSString
    let lineStarts = lspLineStartOffsets(in: content)

    func offset(line: Int, character: Int) -> Int {
        guard line >= 0, line < lineStarts.count else { return ns.length }
        return min(lineStarts[line] + character, ns.length)
    }

    let ranged: [(range: NSRange, newText: String)] = edits.compactMap { edit in
        let start = offset(line: edit.startLine, character: edit.startCharacter)
        let end   = offset(line: edit.endLine, character: edit.endCharacter)
        guard end >= start else { return nil }
        return (NSRange(location: start, length: end - start), edit.newText)
    }

    let result = NSMutableString(string: content)
    for (range, newText) in ranged.sorted(by: { $0.range.location > $1.range.location }) {
        guard range.location + range.length <= result.length else { continue }
        result.replaceCharacters(in: range, with: newText)
    }
    return result as String
}

/// Returns the UTF-16 offset at which each line starts in `content`
/// (index 0 is always 0; index 1 is the offset right after the first
/// `"\n"`, etc.) — used to convert LSP's 0-based `(line, character)`
/// positions into absolute UTF-16 offsets into `content`.
private func lspLineStartOffsets(in content: String) -> [Int] {
    var offsets = [0]
    var offset = 0
    for unit in content.utf16 {
        offset += 1
        if unit == 0x0A { offsets.append(offset) }
    }
    return offsets
}
