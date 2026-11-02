// AppState+Tests.swift
// Athena — Testing sidebar state: discovery, run all / file / test / failed, gutter marks.
// Swift 6, strict concurrency.

import Foundation

// MARK: - TestCenter

@Observable @MainActor
final class TestCenter {
    var frameworks: [TestFramework] = []
    var files: [TestFileNode] = []
    /// Latest result per test, keyed by `TestCaseResult.id`.
    var results: [String: TestCaseResult] = [:]
    /// Keys (`path + US + fullName`) of tests in the run that is in flight.
    var runningKeys: Set<String> = []
    var isRunning = false
    var lastError: String?
    var lastSummary: String?
    @ObservationIgnored let service = TestRunnerService()
    @ObservationIgnored var runTask: Task<Void, Never>?

    nonisolated static func key(_ path: String, _ fullName: String) -> String { path + "\u{1F}" + fullName }

    func status(path: String, fullName: String) -> TestStatus {
        let k = Self.key(path, fullName)
        if runningKeys.contains(k) { return .running }
        return results[k]?.status ?? .unknown
    }

    var failedResults: [TestCaseResult] { results.values.filter { $0.status == .failed } }
}

// MARK: - AppState

@MainActor
extension AppState {

    // MARK: - Discovery

    func refreshTests() async {
        guard let root = workspace?.rootURL else {
            testCenter.frameworks = []; testCenter.files = []; testCenter.results = [:]
            return
        }
        let found = await testCenter.service.discover(root: root)
        testCenter.frameworks = found.frameworks
        testCenter.files = found.files
    }

    // MARK: - Running

    func runAllTests() { runTests(.all) }

    func rerunFailedTests() {
        let failed = testCenter.failedResults
        guard !failed.isEmpty else { statusMessage = "No failed tests to re-run."; return }
        runTests(.failed(failed))
    }

    func stopTests() {
        testCenter.runTask?.cancel()
        Task { await testCenter.service.stop() }
    }

    /// Runs `scope`, grouped per framework (a workspace can have several).
    func runTests(_ scope: TestRunScope) {
        guard let root = workspace?.rootURL else { return }
        let center = testCenter
        guard !center.isRunning else { statusMessage = "Tests are already running."; return }

        // Which framework runs which part of the scope.
        var jobs: [(TestFramework, TestRunScope)] = []
        switch scope {
        case .all:
            jobs = center.frameworks.map { ($0, .all) }
        case .file(let path), .test(let path, _):
            if let node = center.files.first(where: { $0.path == path }) { jobs = [(node.framework, scope)] }
        case .failed(let failed):
            let byPath = Dictionary(grouping: failed, by: \.filePath)
            var perFramework: [TestFramework: [TestCaseResult]] = [:]
            for (path, items) in byPath {
                if let node = center.files.first(where: { $0.path == path }) {
                    perFramework[node.framework, default: []] += items
                }
            }
            jobs = perFramework.map { ($0.key, .failed($0.value)) }
        }
        guard !jobs.isEmpty else { statusMessage = "No tests found to run."; return }

        center.runningKeys = Self.keys(in: scope, files: center.files)
        center.isRunning = true
        center.lastError = nil
        let files = center.files
        activeSidebarPanel = .testing

        center.runTask = Task { [weak self] in
            var all: [TestCaseResult] = []
            var errors: [String] = []
            for (framework, jobScope) in jobs {
                if Task.isCancelled { break }
                let outcome = await center.service.run(framework: framework, scope: jobScope, root: root, files: files)
                all += outcome.results
                if let e = outcome.error { errors.append(e) }
                if !outcome.output.isEmpty, outcome.results.contains(where: { $0.status == .failed }) || outcome.error != nil {
                    self?.scriptOutput += "\n> \(framework.displayName)\n" + outcome.output
                }
            }
            if case .all = scope { center.results = [:] }
            for r in all { center.results[r.id] = r }
            center.runningKeys = []
            center.isRunning = false
            center.lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
            let failed = all.filter { $0.status == .failed }.count
            let passed = all.filter { $0.status == .passed }.count
            center.lastSummary = "\(passed) passed, \(failed) failed"
            self?.statusMessage = "Tests: \(center.lastSummary ?? "")"
        }
    }

    /// Keys of the declared tests a scope covers (to show them as running).
    nonisolated static func keys(in scope: TestRunScope, files: [TestFileNode]) -> Set<String> {
        func all(_ node: TestFileNode) -> [String] {
            node.declarations.map { TestCenter.key(node.path, $0.fullName) }
        }
        switch scope {
        case .all: return Set(files.flatMap(all))
        case .file(let p): return Set(files.filter { $0.path == p }.flatMap(all))
        case .test(let p, let n): return [TestCenter.key(p, n)]
        case .failed(let items): return Set(items.map { TestCenter.key($0.filePath, $0.fullName) })
        }
    }

    // MARK: - Gutter

    /// Run-icon lines for a test file's buffer: line -> state. Empty for
    /// anything that doesn't look like a test file.
    func testGutterMarks(for tab: TabModel) -> [Int: TestStatus] {
        guard let url = tab.fileURL, !testCenter.frameworks.isEmpty,
              TestDiscovery.looksLikeTestFile(url.path), tab.content.utf8.count < 400_000,
              let node = testCenter.files.first(where: { $0.path == url.path })
                ?? Self.provisionalNode(for: url, frameworks: testCenter.frameworks, content: tab.content)
        else { return [:] }
        var marks: [Int: TestStatus] = [:]
        for d in TestDiscovery.declarations(in: tab.content, framework: node.framework) {
            marks[d.line] = testCenter.status(path: url.path, fullName: d.fullName)
        }
        return marks
    }

    private static func provisionalNode(for url: URL, frameworks: [TestFramework], content: String) -> TestFileNode? {
        guard let fw = TestDiscovery.framework(forRelativePath: url.path, detected: frameworks) else { return nil }
        return TestFileNode(path: url.path, framework: fw, declarations: [])
    }

    /// Gutter click on a test/suite line: run that test (a suite runs its file).
    func runTest(at line: Int, in tab: TabModel) {
        guard let url = tab.fileURL,
              let fw = testCenter.files.first(where: { $0.path == url.path })?.framework
                ?? TestDiscovery.framework(forRelativePath: url.path, detected: testCenter.frameworks),
              let decl = TestDiscovery.declarations(in: tab.content, framework: fw).first(where: { $0.line == line })
        else { return }
        if !testCenter.files.contains(where: { $0.path == url.path }) {
            testCenter.files.append(TestFileNode(path: url.path, framework: fw,
                                                 declarations: TestDiscovery.declarations(in: tab.content, framework: fw)))
        }
        runTests(decl.isSuite ? .file(path: url.path) : .test(path: url.path, fullName: decl.fullName))
    }
}
