// SFCCDebugSession.swift
// Athena — one SFCC server-script debug session over SDAPI: breakpoints, halted-thread polling, stepping.
// Swift 6, strict concurrency.

import Foundation

// MARK: - SFCCDebugSession

/// The third `DebugService` backend (after DAP and CDP), see ADR 0002.
/// SDAPI has no push channel: the sandbox halts a request thread at a
/// breakpoint and the client discovers it by polling `threads`. This actor
/// owns that loop, the 30-second timeout reset that keeps a halted thread
/// halted, and the Script Path ↔ local file translation.
actor SFCCDebugSession {

    typealias StateCallback  = @Sendable (DebugState) -> Void
    typealias OutputCallback = @Sendable (String) -> Void
    typealias StopCallback   = @Sendable (DebugStop) -> Void

    private let client: SDAPIClient
    private let cartridges: SFCCCartridgeMap
    private let onStateChange: StateCallback
    private let onOutput: OutputCallback
    private let onStopped: StopCallback
    private let pollInterval: Duration
    private let keepAliveInterval: Duration

    private var pollTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?

    /// `isActive` flips on once `start` has registered everything and off
    /// at the top of `stop`; every `await` in the poll paths re-checks it,
    /// because a response can land after teardown began. `isStopped` is
    /// the one-way latch `start` checks between its own awaits so a Stop
    /// pressed during launch unwinds instead of racing the launch.
    private var isActive = false
    private var isStopped = false
    private var isStepping = false
    private var consecutivePollFailures = 0
    private var breakpointsByFile: [String: [Int]] = [:]

    /// The halted thread the UI is currently looking at. SDAPI can halt
    /// several request threads at once; they're surfaced one at a time.
    /// Changing threads forgets the last reported location, so a thread
    /// re-hitting the same breakpoint after Continue is reported again.
    private var currentThreadId: Int? {
        didSet { if currentThreadId != oldValue { lastReportedLocation = nil } }
    }
    private var lastReportedLocation: (thread: Int, line: Int, path: String)?

    init(client: SDAPIClient,
         cartridges: SFCCCartridgeMap,
         onStateChange: @escaping StateCallback,
         onOutput: @escaping OutputCallback,
         onStopped: @escaping StopCallback,
         pollInterval: Duration = .seconds(2),
         keepAliveInterval: Duration = .seconds(30)) {
        self.client = client
        self.cartridges = cartridges
        self.onStateChange = onStateChange
        self.onOutput = onOutput
        self.onStopped = onStopped
        self.pollInterval = pollInterval
        self.keepAliveInterval = keepAliveInterval
    }

    // MARK: - Lifecycle

    /// Registers the client, clears breakpoints a crashed Athena may have
    /// left under the same client id, pushes ours, and starts polling.
    /// Throws `CancellationError` if `stop()` was called meanwhile.
    func start(breakpointsByFile: [String: [Int]]) async throws {
        self.breakpointsByFile = breakpointsByFile
        try await client.createClient()
        try await unwindIfStopped()
        try? await client.removeAllBreakpoints()
        try await unwindIfStopped()
        try await pushBreakpoints()
        try await unwindIfStopped()

        isActive = true
        onStateChange(.running)
        onOutput("[SFCC] Waiting for a storefront request to hit a breakpoint…\n")

        pollTask = Task { [weak self, pollInterval] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollThreads()
                try? await clock.sleep(until: clock.now.advanced(by: pollInterval))
            }
        }
        keepAliveTask = Task { [weak self, keepAliveInterval] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                try? await clock.sleep(until: clock.now.advanced(by: keepAliveInterval))
                guard let self, !Task.isCancelled else { return }
                await self.keepAlive()
            }
        }
    }

    /// Idempotent. Always emits `.stopped` so the UI leaves `.launching`
    /// even when Stop lands before `start` finished.
    func stop() async {
        let firstCall = !isStopped
        isStopped = true
        pollTask?.cancel(); keepAliveTask?.cancel(); burstTask?.cancel()
        pollTask = nil; keepAliveTask = nil; burstTask = nil
        let wasActive = isActive
        isActive = false
        currentThreadId = nil
        if wasActive {
            try? await client.removeAllBreakpoints()
            try? await client.deleteClient()
        }
        if firstCall { onStateChange(.stopped) }
    }

    /// Replaces the sandbox's breakpoint set with `byFile` — SDAPI only
    /// appends, so the old set is deleted first.
    func updateBreakpoints(byFile: [String: [Int]]) async throws {
        breakpointsByFile = byFile
        guard isActive else { return }
        try await client.removeAllBreakpoints()
        try await pushBreakpoints()
    }

    // MARK: - Controls

    func resume() async throws {
        guard let thread = currentThreadId else { throw SDAPIError.notPaused }
        currentThreadId = nil
        onStateChange(.running)
        try await client.resume(thread: thread)
        scheduleBurst()
    }

    func step(_ kind: SDAPIClient.StepKind) async throws {
        guard let thread = currentThreadId else { throw SDAPIError.notPaused }
        // Polling pauses for the request so a poll can't re-report the old
        // line while the sandbox is still moving the thread.
        isStepping = true
        lastReportedLocation = nil
        onStateChange(.running)
        defer { isStepping = false }
        try await client.step(kind, thread: thread)
        scheduleBurst()
    }

    // MARK: - Inspection

    func stackFrames() async throws -> [DebugStackFrame] {
        guard let threadId = currentThreadId else { return [] }
        let thread = try await client.thread(threadId)
        return thread.callStack.map { frame in
            let name = frame.location.functionName.isEmpty ? "<anonymous>" : frame.location.functionName
            return DebugStackFrame(
                id: frame.index,
                name: name,
                sourceURL: cartridges.localURL(for: frame.location.scriptPath),
                line: frame.location.lineNumber,
                column: 1
            )
        }
    }

    func variables(frameIndex: Int) async throws -> [DebugVariable] {
        guard let threadId = currentThreadId else { return [] }
        let members = try await client.variables(thread: threadId, frame: frameIndex)
        return members
            .filter { $0.scope != "global" }
            .map { DebugVariable(name: $0.name, value: $0.value ?? "undefined", type: $0.type, variablesReference: 0) }
    }

    func evaluate(_ expression: String, frameIndex: Int?) async throws -> DAPEvaluateResult {
        guard let threadId = currentThreadId else { throw SDAPIError.notPaused }
        let result = try await client.evaluate(thread: threadId, frame: frameIndex ?? 0, expression: expression)
        return DAPEvaluateResult(result: result, type: nil, variablesReference: 0)
    }

    // MARK: - Breakpoints

    private func pushBreakpoints() async throws {
        var entries: [(scriptPath: String, line: Int)] = []
        for (file, lines) in breakpointsByFile.sorted(by: { $0.key < $1.key }) {
            guard let scriptPath = cartridges.scriptPath(for: URL(fileURLWithPath: file)) else {
                onOutput("[SFCC] Skipping breakpoint(s) in \(file): not inside a cartridge\n")
                continue
            }
            entries += lines.sorted().map { (scriptPath: scriptPath, line: $0) }
        }
        if entries.isEmpty {
            onOutput("[SFCC] No breakpoints inside cartridges — the session will not pause\n")
            return
        }
        let set = try await client.setBreakpoints(entries)
        onOutput("[SFCC] \(set.count) breakpoint(s) set on the sandbox\n")
    }

    private func unwindIfStopped() async throws {
        guard isStopped else { return }
        try? await client.removeAllBreakpoints()
        try? await client.deleteClient()
        throw CancellationError()
    }

    // MARK: - Polling

    /// Finds a halted thread to surface. Sticks with `currentThreadId` while
    /// it stays halted (a step lands on a new line of the same thread, which
    /// is re-reported); once it finishes, the next halted thread takes over.
    /// Returns whether a thread is halted afterwards, for the post-step burst.
    @discardableResult
    private func pollThreads() async -> Bool {
        guard isActive, !isStepping else { return currentThreadId != nil }
        let threads: [SFCCDebugThread]
        do {
            threads = try await client.threads()
            consecutivePollFailures = 0
        } catch {
            await handlePollFailure(error)
            return false
        }
        guard isActive, !isStepping else { return currentThreadId != nil }

        if let current = currentThreadId,
           let thread = threads.first(where: { $0.id == current }) {
            if thread.status == .halted {
                report(thread)
            } else {
                currentThreadId = nil
                onStateChange(.running)
            }
            return currentThreadId != nil
        }

        currentThreadId = nil
        if let halted = threads.filter({ $0.status == .halted }).min(by: { $0.id < $1.id }) {
            currentThreadId = halted.id
            report(halted)
        }
        return currentThreadId != nil
    }

    /// After resume/step the sandbox halts again within milliseconds, not
    /// seconds — poll quickly for a moment so stepping feels immediate.
    /// Detached from the control call so Continue/Step return at once.
    private func scheduleBurst() {
        burstTask?.cancel()
        burstTask = Task { [weak self] in
            let clock = ContinuousClock()
            for _ in 0..<8 {
                try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(150)))
                guard let self, !Task.isCancelled else { return }
                if await self.pollThreads() { return }
            }
        }
    }

    private func report(_ thread: SFCCDebugThread) {
        let top = thread.callStack.first
        let path = top.flatMap { cartridges.localURL(for: $0.location.scriptPath)?.path }
        let line = top?.location.lineNumber
        let key = (thread: thread.id, line: line ?? 0, path: path ?? top?.location.scriptPath ?? "")
        if let last = lastReportedLocation, last == key { return }
        lastReportedLocation = key
        if path == nil, let scriptPath = top?.location.scriptPath {
            onOutput("[SFCC] Halted in \(scriptPath) but no local cartridge matches it\n")
        }
        onStateChange(.paused(reason: "breakpoint"))
        onStopped(DebugStop(reason: "breakpoint", threadId: thread.id, filePath: path, line: line))
    }

    /// A single failed poll is reported once; auth loss or a run of failures
    /// ends the session instead of showing "Running" against nothing.
    private func handlePollFailure(_ error: Error) async {
        consecutivePollFailures += 1
        if consecutivePollFailures == 1 {
            onOutput("[SFCC] Polling failed: \(error.localizedDescription)\n")
        }
        let fatal: Bool
        if case SDAPIError.http(let status, _) = error, status == 401 || status == 403 {
            fatal = true
        } else {
            fatal = consecutivePollFailures >= 5
        }
        if fatal, isActive {
            onOutput("[SFCC] Sandbox unreachable — stopping the session\n")
            await stop()
        }
    }

    private func keepAlive() async {
        guard isActive else { return }
        do {
            try await client.resetThreads()
        } catch {
            onOutput("[SFCC] Keep-alive failed: \(error.localizedDescription)\n")
        }
    }
}
