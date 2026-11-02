// BenchmarkTests.swift
// Athena — repeatable timing measurements. Prints numbers; asserts only that work happened.
// Swift 6, strict concurrency.
//
// Run:  swift test --filter AthenaBenchmarks   (look for "[bench]" lines)
// No pass/fail thresholds on purpose: timings vary by machine and load.

import Testing
import Foundation
import AppKit
@testable import Athena

@Suite("AthenaBenchmarks")
struct AthenaBenchmarks {

    private func report(_ name: String, _ samplesMs: [Double]) {
        let s = samplesMs.sorted()
        let median = s[s.count / 2]
        let p95 = s[min(s.count - 1, Int(Double(s.count) * 0.95))]
        print(String(format: "[bench] %@: n=%d median=%.3fms p95=%.3fms max=%.3fms",
                     name, s.count, median, p95, s.last ?? 0))
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// One keystroke on a 10k-line TypeScript file: plan the highlight range, then apply it.
    @MainActor @Test func typingLatencyOn10kLineFile() {
        let line = "const value = compute(\"text\", 42); // trailing comment"
        let source = (0..<10_000).map { _ in line }.joined(separator: "\n")
        let storage = NSTextStorage(string: source)
        let highlighter = SyntaxHighlighter(language: .typescript, theme: .athenaDark)
        let clock = ContinuousClock()
        let fullPass = clock.measure {
            highlighter.apply(to: storage, range: NSRange(location: 0, length: storage.length))
        }
        print(String(format: "[bench] full highlight of 10000 lines: %.1fms", ms(fullPass)))

        var samples: [Double] = []
        var windows = 0, fulls = 0
        let lineLength = (line as NSString).length + 1
        for i in 0..<100 {
            let location = 5000 * lineLength + i * lineLength + 6   // inside "value" on a different line each time
            let elapsed = clock.measure {
                storage.replaceCharacters(in: NSRange(location: location, length: 0), with: "x")
                let plan = HighlightPlanner.plan(
                    text: storage.string as NSString,
                    edit: HighlightEdit(range: NSRange(location: location, length: 1), deletedText: ""),
                    language: .typescript, isNewlineColored: { _ in false })
                switch plan {
                case .window(let r): windows += 1; highlighter.apply(to: storage, range: r)
                case .full:          fulls += 1;   highlighter.apply(to: storage, range: NSRange(location: 0, length: storage.length))
                }
            }
            samples.append(ms(elapsed))
        }
        #expect(windows + fulls == 100)
        print("[bench] keystroke plans: window=\(windows) full=\(fulls)")
        report("typing keystroke (plan + apply), 10k lines", samples)
    }

    /// Time to build the file tree for a synthetic workspace.
    @Test func workspaceScanTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("athena-bench-ws")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        for d in 0..<100 {
            let dir = root.appendingPathComponent("src/pkg\(d)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<30 { try "x".write(to: dir.appendingPathComponent("f\(f).ts"), atomically: false, encoding: .utf8) }
        }
        let service = FileService()
        let clock = ContinuousClock()
        var samples: [Double] = []
        var nodes = 0
        for _ in 0..<5 {
            let start = clock.now
            nodes = try await service.buildFileTree(root).count
            samples.append(ms(start.duration(to: clock.now)))
        }
        #expect(nodes > 0)
        report("workspace scan, 3000 files in 100 dirs", samples)
    }
}
