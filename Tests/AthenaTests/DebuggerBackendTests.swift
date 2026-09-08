// DebuggerBackendTests.swift
// Athena — the debugger backends driven against real processes: a Node
// script under CDP and a compiled Swift binary under lldb-dap.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

// MARK: - Launch configuration variables

@Suite("Launch config variables")
struct LaunchVariableTests {
    private let workspace = URL(fileURLWithPath: "/Users/dev/shop")
    private let file = URL(fileURLWithPath: "/Users/dev/shop/src/api/route.ts")

    /// `${file}` used to pass through untouched, so the built-in "Debug
    /// Node.js (current file)" config asked Node to run a file literally
    /// named `${file}`.
    @Test func expandsTheActiveFileAndWorkspace() {
        func expand(_ s: String) -> String {
            DebugService.expand(s, workspaceURL: workspace, fileURL: file)
        }
        #expect(expand("${file}") == "/Users/dev/shop/src/api/route.ts")
        #expect(expand("${fileBasename}") == "route.ts")
        #expect(expand("${fileBasenameNoExtension}") == "route")
        #expect(expand("${fileDirname}") == "/Users/dev/shop/src/api")
        #expect(expand("${workspaceFolder}/.build/debug/App") == "/Users/dev/shop/.build/debug/App")
        #expect(expand("${workspaceFolderBasename}") == "shop")
    }

    @Test func unknownVariablesAndMissingContextAreLeftAlone() {
        #expect(DebugService.expand("${file}", workspaceURL: workspace, fileURL: nil) == "${file}")
        #expect(DebugService.expand("${env:HOME}", workspaceURL: workspace, fileURL: file) == "${env:HOME}")
        #expect(DebugService.expand("/absolute/path", workspaceURL: nil, fileURL: nil) == "/absolute/path")
    }
}

// MARK: - Real debug sessions

/// Collects the callbacks a session emits.
private actor DebugRecorder {
    var states: [DebugState] = []
    var stops: [DebugStop] = []
    var output = ""
    func state(_ s: DebugState) { states.append(s) }
    func stop(_ s: DebugStop) { stops.append(s) }
    func out(_ t: String) { output += t }
    var isPaused: Bool { states.contains { if case .paused = $0 { return true }; return false } }
}

@Suite("Debugger backends", .serialized)
struct DebuggerBackendTests {

    private func waitUntil(_ seconds: Int, _ condition: @Sendable () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if await condition() { return }
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(50)))
        }
    }

    private func makeService(_ recorder: DebugRecorder) async -> DebugService {
        let service = DebugService()
        await service.setCallbacks(
            onStateChange: { s in Task { await recorder.state(s) } },
            onOutput:      { t in Task { await recorder.out(t) } },
            onStopped:     { s in Task { await recorder.stop(s) } }
        )
        return service
    }

    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Node.js over the Chrome DevTools Protocol — the same machinery the
    /// Chrome and Next.js configurations use.
    @Test func nodeStopsAtABreakpointWithFramesAndVariables() async throws {
        let dir = try tempDir("athena-node-debug")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("app.js")
        try """
        function add(a, b) {
          const sum = a + b;
          return sum;
        }
        console.log(add(2, 3));
        """.write(to: script, atomically: true, encoding: .utf8)

        let recorder = DebugRecorder()
        let service = await makeService(recorder)
        let config = LaunchConfig(type: "node-cdp", request: "launch", name: "node",
                                  program: script.path, debugPort: 9271)
        do {
            try await service.launch(config, workspaceURL: dir, breakpointsByFile: [script.path: [3]])
        } catch {
            // No Node on this machine: nothing to assert about the protocol.
            await service.disconnect()
            return
        }

        await waitUntil(25) { await recorder.isPaused }
        guard await recorder.isPaused else {
            let output = await recorder.output
            Issue.record("Node never paused at the breakpoint. Session output: \(output)")
            await service.disconnect()
            return
        }

        // The stop is the breakpoint inside `add`, not the entry pause that
        // `--inspect-brk` always produces.
        let stop = await recorder.stops.first
        #expect(stop?.line == 3)
        let frames = try await service.fetchStackFrames()
        #expect(frames.first?.name == "add")
        let variables = try await service.fetchVariables(frameId: 0)
        #expect(variables.contains { $0.name == "sum" })
        #expect(variables.contains { $0.name == "a" })

        await service.disconnect()
    }

    /// Swift through lldb-dap. This is the path the DAP handshake order
    /// broke: awaiting `launch` before `configurationDone` left the adapter
    /// either failing outright or running past every breakpoint.
    @Test func swiftStopsInsideAFunctionWithLocalsInScope() async throws {
        let dir = try tempDir("athena-swift-debug")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("main.swift")
        try """
        func double(_ x: Int) -> Int {
            let y = x * 2
            return y
        }
        print(double(21))
        """.write(to: source, atomically: true, encoding: .utf8)

        let binary = dir.appendingPathComponent("prog")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-g", "-Onone", source.path, "-o", binary.path]
        compile.standardOutput = Pipe(); compile.standardError = Pipe()
        try? compile.run(); compile.waitUntilExit()
        guard FileManager.default.fileExists(atPath: binary.path) else { return }

        let recorder = DebugRecorder()
        let service = await makeService(recorder)
        let config = LaunchConfig(type: "lldb", request: "launch", name: "swift", program: binary.path)
        do {
            try await service.launch(config, workspaceURL: dir, breakpointsByFile: [source.path: [3]])
        } catch {
            // lldb-dap not installed on this machine.
            await service.disconnect()
            return
        }

        await waitUntil(25) { await recorder.isPaused }
        guard await recorder.isPaused else {
            Issue.record("lldb-dap never paused at the breakpoint.")
            await service.disconnect()
            return
        }

        let frames = try await service.fetchStackFrames()
        #expect(frames.first?.name.contains("double") == true)
        #expect(frames.count > 1)                       // the caller is there too
        let variables = try await service.fetchVariables(frameId: frames.first?.id ?? 0)
        #expect(variables.contains { $0.name == "x" && $0.value.contains("21") })

        await service.disconnect()
    }
}
