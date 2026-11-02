// ProcessCapture.swift
// Athena — runs a subprocess to completion, capturing output; cancellable via a handle.
// Swift 6, strict concurrency.

import Foundation

// MARK: - ProcessHandle

/// Lets an actor terminate a process that `ProcessCapture.run` owns.
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    fileprivate func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        process = p
        return true
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

// MARK: - ProcessCapture

struct ProcessResult: Sendable {
    var stdout: String
    var stderr: String
    var status: Int32
}

enum ProcessCapture {

    /// Runs `executable` and waits. Both pipes are drained on GCD threads
    /// (never `FileHandle.bytes`, which stalls on a full pipe) before the
    /// exit status is read. `GIT_CONFIG_*` is stripped, as the Makefile does,
    /// because the shell hook injects them. With `mergeStderr` the two
    /// streams share one pipe, in arrival order.
    static func run(
        executable: URL,
        arguments: [String],
        cwd: URL,
        environment: [String: String] = [:],
        mergeStderr: Bool = false,
        handle: ProcessHandle? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("GIT_CONFIG_") { env[key] = nil }
        for (k, v) in environment { env[k] = v }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = mergeStderr ? outPipe : Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        if let handle, !handle.attach(process) { throw CancellationError() }
        try process.run()

        return await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let group = DispatchGroup()
                nonisolated(unsafe) var outData = Data()
                nonisolated(unsafe) var errData = Data()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                if !mergeStderr {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                }
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: ProcessResult(
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self),
                    status: process.terminationStatus))
            }
        }
    }

    /// Runs `command` through the user's login shell, so `npm`/`node` from
    /// nvm/Homebrew resolve as they do in the terminal.
    static func runLoginShell(
        _ command: String, cwd: URL, handle: ProcessHandle? = nil
    ) async throws -> ProcessResult {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return try await run(executable: URL(fileURLWithPath: shell), arguments: ["-l", "-c", command],
                             cwd: cwd, handle: handle)
    }
}
