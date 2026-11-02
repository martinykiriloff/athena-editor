// CrashLog.swift
// Athena — local-only crash/diagnostic log (uncaught Obj-C exceptions, fatal signals).
// Swift 6, strict concurrency.
//
// Reports are written to ~/Library/Application Support/Athena/logs/ and never
// leave the machine. There is no telemetry and no remote reporting.

@preconcurrency import AppKit
import Foundation

enum CrashLog {

    // MARK: - Locations

    static func logsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Athena/logs", isDirectory: true)
    }

    // MARK: - Report format (pure)

    static func report(kind: String, detail: String, version: String, date: Date, stack: [String] = []) -> String {
        var lines = [
            "Athena crash report",
            "Kind: \(kind)",
            "Detail: \(detail)",
            "Version: \(version)",
            "Date: \(ISO8601DateFormatter().string(from: date))",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        if !stack.isEmpty { lines.append("Stack:"); lines += stack.map { "  " + $0 } }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `text` to a new timestamped file in `directory`; returns its URL.
    @discardableResult
    static func write(_ text: String, kind: String, to directory: URL, date: Date = .now) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(date.timeIntervalSince1970)
        let url = directory.appendingPathComponent("crash-\(kind)-\(stamp).log")
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    // MARK: - Installation

    private static let versionString: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// Pre-opened descriptor for the signal handler (open/malloc are not signal-safe).
    nonisolated(unsafe) private static var signalFD: Int32 = -1
    nonisolated(unsafe) private static var signalPrefix: [UInt8] = []

    /// Installs the Obj-C exception handler and fatal-signal handlers. Call once at launch.
    static func install() {
        let dir = logsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("last-signal.log").path
        signalFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        signalPrefix = Array("Athena fatal signal report\nVersion: \(versionString)\nSignal: ".utf8)

        NSSetUncaughtExceptionHandler { exception in
            let text = CrashLog.report(
                kind: "exception",
                detail: "\(exception.name.rawValue): \(exception.reason ?? "no reason")",
                version: CrashLog.versionString, date: .now,
                stack: exception.callStackSymbols)
            CrashLog.write(text, kind: "exception", to: CrashLog.logsDirectory())
        }

        for sig in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGFPE, SIGTRAP] {
            signal(sig) { number in
                // Async-signal-safe only: write(2) on a pre-opened fd, then re-raise.
                let fd = CrashLog.signalFD
                if fd >= 0 {
                    CrashLog.signalPrefix.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
                    var digits: [UInt8] = []
                    var n = Int(number)
                    repeat { digits.insert(UInt8(48 + n % 10), at: 0); n /= 10 } while n > 0
                    digits.append(10)
                    digits.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
                    close(fd)
                }
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    // MARK: - Show Logs

    @MainActor
    static func showLogsInFinder() {
        let dir = logsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
