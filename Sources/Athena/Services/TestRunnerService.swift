// TestRunnerService.swift
// Athena — discovers and runs Jest, Vitest, pytest and swift test; parses their structured output.
// Swift 6, strict concurrency.

import Foundation

// MARK: - TestRunnerService

actor TestRunnerService {

    private var handle: ProcessHandle?

    // MARK: - Discovery

    /// Frameworks the workspace uses and every test file with its declarations.
    func discover(root: URL) -> (frameworks: [TestFramework], files: [TestFileNode]) {
        let fm = FileManager.default
        func text(_ name: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        let rootFiles = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        let frameworks = TestDiscovery.detectFrameworks(
            packageJSON: text("package.json"), rootFiles: rootFiles,
            pyproject: text("pyproject.toml"), toxIni: text("tox.ini"), setupCfg: text("setup.cfg"))
        guard !frameworks.isEmpty else { return ([], []) }

        let skip: Set<String> = ["node_modules", ".git", ".build", "venv", ".venv", "dist", "build",
                                 "__pycache__", "Pods", "DerivedData", ".next", "coverage"]
        var files: [TestFileNode] = []
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return (frameworks, []) }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 30_000 { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skip.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            guard let framework = TestDiscovery.framework(forRelativePath: rel, detected: frameworks),
                  (values?.fileSize ?? 0) < 1_000_000,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let decls = TestDiscovery.declarations(in: content, framework: framework)
            if !decls.isEmpty {
                files.append(TestFileNode(path: url.path, framework: framework, declarations: decls))
            }
        }
        files.sort { $0.path < $1.path }
        return (frameworks, files)
    }

    // MARK: - Running

    func stop() { handle?.terminate() }

    func run(framework: TestFramework, scope: TestRunScope, root: URL, files: [TestFileNode]) async -> TestRunOutcome {
        let tmp = NSTemporaryDirectory() + "athena-test-\(UUID().uuidString)"
        let report = tmp + (framework == .pytest ? ".xml" : ".json")
        defer { try? FileManager.default.removeItem(atPath: report) }

        guard let inv = TestCommand.invocation(framework: framework, scope: scope, root: root, reportPath: report) else {
            return TestRunOutcome(results: [], output: "", exitStatus: -1,
                                  error: "\(framework.displayName) is not installed in this workspace.")
        }
        let h = ProcessHandle()
        handle = h
        defer { handle = nil }
        let result: ProcessResult
        do {
            result = try await ProcessCapture.run(executable: inv.executable, arguments: inv.arguments, cwd: root,
                                                  mergeStderr: framework == .swiftTest, handle: h)
        } catch {
            return TestRunOutcome(results: [], output: "", exitStatus: -1, error: error.localizedDescription)
        }
        let output = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)

        var results: [TestCaseResult]
        switch framework {
        case .jest, .vitest:
            let data = (try? Data(contentsOf: URL(fileURLWithPath: report))) ?? Data()
            results = TestOutputParser.parseJestJSON(data)
        case .pytest:
            let data = (try? Data(contentsOf: URL(fileURLWithPath: report))) ?? Data()
            results = TestOutputParser.parseJUnit(data, root: root)
        case .swiftTest:
            results = TestOutputParser.parseSwiftTest(output)
            // swift test names a test, not a file: fill it in from discovery.
            for i in results.indices where results[i].filePath.isEmpty {
                let name = results[i].fullName
                results[i].filePath = files.first { node in
                    node.declarations.contains { $0.fullName == name || $0.fullName.hasSuffix("/" + name) }
                }?.path ?? ""
            }
        }
        var error: String?
        if results.isEmpty && result.status != 0 {
            error = "\(framework.displayName) exited with status \(result.status) and reported no tests."
        }
        return TestRunOutcome(results: results, output: output, exitStatus: result.status, error: error)
    }
}

// MARK: - TestCommand

enum TestCommand {

    struct Invocation: Equatable {
        var executable: URL
        var arguments: [String]
    }

    /// The command for `scope`. `nil` when the framework's runner is not installed.
    static func invocation(
        framework: TestFramework, scope: TestRunScope, root: URL, reportPath: String,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Invocation? {
        func bin(_ name: String) -> URL? {
            let p = root.appendingPathComponent("node_modules/.bin/\(name)").path
            return fileExists(p) ? URL(fileURLWithPath: p) : nil
        }
        func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

        switch framework {
        case .jest, .vitest:
            let name = framework == .jest ? "jest" : "vitest"
            guard let exe = bin(name) else { return nil }
            var args: [String]
            if framework == .jest {
                args = ["--json", "--outputFile=\(reportPath)"]
            } else {
                args = ["run", "--reporter=json", "--outputFile=\(reportPath)"]
            }
            let pathFlag: [String] = framework == .jest ? ["--runTestsByPath"] : []
            switch scope {
            case .all: break
            case .file(let path): args += pathFlag + [path]
            case .test(let path, let full): args += pathFlag + [path, "-t", "^" + escape(full) + "$"]
            case .failed(let failed):
                let paths = orderedUnique(failed.map(\.filePath))
                args += pathFlag + paths + ["-t", "^(" + failed.map { escape($0.fullName) }.joined(separator: "|") + ")$"]
            }
            return Invocation(executable: exe, arguments: args)

        case .pytest:
            var args = ["-q", "-o", "junit_family=xunit2", "--junitxml=\(reportPath)"]
            switch scope {
            case .all: break
            case .file(let path): args.append(path)
            case .test(let path, let full): args.append(path + "::" + full)
            case .failed(let failed): args += failed.map { $0.filePath + "::" + $0.fullName }
            }
            for venv in [".venv/bin/pytest", "venv/bin/pytest"] {
                let p = root.appendingPathComponent(venv).path
                if fileExists(p) { return Invocation(executable: URL(fileURLWithPath: p), arguments: args) }
            }
            return Invocation(executable: URL(fileURLWithPath: "/usr/bin/env"),
                              arguments: ["python3", "-m", "pytest"] + args)

        case .swiftTest:
            guard fileExists("/usr/bin/swift") else { return nil }
            var args = ["test"]
            switch scope {
            case .all: break
            case .file(let path):
                // Every class/struct declared in the file.
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    for d in TestDiscovery.declarations(in: text, framework: .swiftTest) where d.isSuite {
                        args += ["--filter", escape(d.title) + "/"]
                    }
                }
            case .test(_, let full): args += ["--filter", escape(full) + "$"]
            case .failed(let failed):
                for f in failed { args += ["--filter", escape(f.fullName) + "$"] }
            }
            return Invocation(executable: URL(fileURLWithPath: "/usr/bin/swift"), arguments: args)
        }
    }

    private static func orderedUnique(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }
}

// MARK: - TestDiscovery

enum TestDiscovery {

    static func detectFrameworks(
        packageJSON: String?, rootFiles: Set<String>,
        pyproject: String?, toxIni: String?, setupCfg: String?
    ) -> [TestFramework] {
        var found: [TestFramework] = []
        var deps: Set<String> = []
        if let packageJSON,
           let root = try? JSONSerialization.jsonObject(with: Data(packageJSON.utf8)) as? [String: Any] {
            for key in ["dependencies", "devDependencies"] {
                deps.formUnion((root[key] as? [String: Any])?.keys ?? [:].keys)
            }
        }
        if deps.contains("vitest") || rootFiles.contains(where: { $0.hasPrefix("vitest.config.") }) {
            found.append(.vitest)
        }
        if deps.contains("jest") || rootFiles.contains(where: { $0.hasPrefix("jest.config.") }) {
            found.append(.jest)
        }
        if rootFiles.contains("pytest.ini") || rootFiles.contains("conftest.py")
            || (pyproject?.contains("[tool.pytest") ?? false)
            || (toxIni?.contains("[pytest]") ?? false)
            || (setupCfg?.contains("[tool:pytest]") ?? false) {
            found.append(.pytest)
        }
        if rootFiles.contains("Package.swift") { found.append(.swiftTest) }
        return found
    }

    /// Which framework owns the file at `rel` (relative to the workspace), if any.
    static func framework(forRelativePath rel: String, detected: [TestFramework]) -> TestFramework? {
        let name = (rel as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        if ["js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts"].contains(ext) {
            let isTest = name.contains(".test.") || name.contains(".spec.") || rel.contains("__tests__/")
            guard isTest else { return nil }
            return detected.first { $0 == .vitest } ?? detected.first { $0 == .jest }
        }
        if ext == "py", detected.contains(.pytest), name.hasPrefix("test_") || name.hasSuffix("_test.py") {
            return .pytest
        }
        if ext == "swift", detected.contains(.swiftTest), rel.hasPrefix("Tests/") || rel.contains("/Tests/") {
            return .swiftTest
        }
        return nil
    }

    /// Cheap filename check, for the editor gutter.
    static func looksLikeTestFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        switch ext {
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts":
            return name.contains(".test.") || name.contains(".spec.") || path.contains("__tests__/")
        case "py": return name.hasPrefix("test_") || name.hasSuffix("_test.py")
        case "swift": return path.contains("/Tests/")
        default: return false
        }
    }

    static func declarations(in text: String, framework: TestFramework) -> [TestDeclaration] {
        switch framework {
        case .jest, .vitest: return jsDeclarations(text)
        case .pytest: return pythonDeclarations(text)
        case .swiftTest: return swiftDeclarations(text)
        }
    }

    // MARK: JS

    private static let jsRegex = try? NSRegularExpression(
        pattern: #"^(\s*)(describe|it|test|suite)(?:\.(?:only|skip|concurrent|todo|sequential|fails))*\s*\(\s*(['"`])((?:\\.|(?!\3).)*)\3"#)

    private static func jsDeclarations(_ text: String) -> [TestDeclaration] {
        var out: [TestDeclaration] = []
        var stack: [(indent: Int, title: String)] = []
        for (index, line) in lines(text).enumerated() {
            guard let m = capture(jsRegex, line), m.count == 4 else { continue }
            let indent = m[0].count
            while let top = stack.last, top.indent >= indent { stack.removeLast() }
            let isSuite = m[1] == "describe" || m[1] == "suite"
            let title = m[3]
            let full = (stack.map(\.title) + [title]).joined(separator: " ")
            out.append(TestDeclaration(line: index + 1, title: title, fullName: full,
                                       isSuite: isSuite, depth: stack.count))
            if isSuite { stack.append((indent, title)) }
        }
        return out
    }

    // MARK: Python

    private static let pyClass = try? NSRegularExpression(pattern: #"^(\s*)class\s+(Test\w*)"#)
    private static let pyDef = try? NSRegularExpression(pattern: #"^(\s*)(?:async\s+)?def\s+(test\w*)\s*\("#)

    private static func pythonDeclarations(_ text: String) -> [TestDeclaration] {
        var out: [TestDeclaration] = []
        var stack: [(indent: Int, name: String)] = []
        for (index, line) in lines(text).enumerated() {
            if let m = capture(pyClass, line) {
                while let top = stack.last, top.indent >= m[0].count { stack.removeLast() }
                out.append(TestDeclaration(line: index + 1, title: m[1], fullName: m[1], isSuite: true, depth: stack.count))
                stack.append((m[0].count, m[1]))
            } else if let m = capture(pyDef, line) {
                while let top = stack.last, top.indent >= m[0].count { stack.removeLast() }
                let full = stack.last.map { $0.name + "::" + m[1] } ?? m[1]
                out.append(TestDeclaration(line: index + 1, title: m[1], fullName: full, isSuite: false, depth: stack.count))
            }
        }
        return out
    }

    // MARK: Swift

    private static let swType = try? NSRegularExpression(
        pattern: #"^(\s*)(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final)\s+)*(?:class|struct|actor)\s+(\w+)(?:\s*:\s*([^{]*))?"#)
    private static let swFunc = try? NSRegularExpression(pattern: #"^(\s*)(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate)\s+)?func\s+(\w+)\s*\("#)

    private static func swiftDeclarations(_ text: String) -> [TestDeclaration] {
        var out: [TestDeclaration] = []
        var stack: [(indent: Int, name: String, isXCTest: Bool)] = []
        var pendingTest = false
        var pendingSuite = false
        for (index, line) in lines(text).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@Test") { pendingTest = true }
            if trimmed.hasPrefix("@Suite") { pendingSuite = true }
            if let m = capture(swType, line) {
                while let top = stack.last, top.indent >= m[0].count { stack.removeLast() }
                let isXC = m[2].contains("XCTestCase")
                if isXC || pendingSuite {
                    out.append(TestDeclaration(line: index + 1, title: m[1], fullName: m[1], isSuite: true, depth: stack.count))
                }
                stack.append((m[0].count, m[1], isXC))
                pendingSuite = false
                pendingTest = false
            } else if let m = capture(swFunc, line) {
                while let top = stack.last, top.indent >= m[0].count { stack.removeLast() }
                let owner = stack.last
                if pendingTest {
                    let full = (owner.map { $0.name + "/" } ?? "") + m[1] + "()"
                    out.append(TestDeclaration(line: index + 1, title: m[1], fullName: full, isSuite: false, depth: stack.count))
                } else if let owner, owner.isXCTest, m[1].hasPrefix("test") {
                    out.append(TestDeclaration(line: index + 1, title: m[1], fullName: owner.name + "/" + m[1],
                                               isSuite: false, depth: stack.count))
                }
                pendingTest = false
            }
        }
        return out
    }

    // MARK: Helpers

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func capture(_ re: NSRegularExpression?, _ line: String) -> [String]? {
        guard let re, let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
    }
}

// MARK: - TestOutputParser

enum TestOutputParser {

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    // MARK: Jest / Vitest (--json)

    static func parseJestJSON(_ data: Data) -> [TestCaseResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["testResults"] as? [[String: Any]] else { return [] }
        var out: [TestCaseResult] = []
        for file in files {
            let path = (file["name"] as? String) ?? (file["testFilePath"] as? String) ?? ""
            let assertions = file["assertionResults"] as? [[String: Any]] ?? []
            if assertions.isEmpty {
                if (file["status"] as? String) == "failed" {
                    out.append(TestCaseResult(filePath: path, fullName: "(test suite failed to run)",
                                              title: "(test suite failed to run)", status: .failed,
                                              message: (file["message"] as? String).map(stripANSI)))
                }
                continue
            }
            for a in assertions {
                let title = a["title"] as? String ?? ""
                let ancestors = (a["ancestorTitles"] as? [String]) ?? []
                let full = (a["fullName"] as? String) ?? (ancestors + [title]).joined(separator: " ")
                let failures = (a["failureMessages"] as? [String]) ?? []
                out.append(TestCaseResult(
                    filePath: path, fullName: full, title: title,
                    status: status(a["status"] as? String),
                    message: failures.isEmpty ? nil : stripANSI(failures.joined(separator: "\n")),
                    duration: (a["duration"] as? Double).map { $0 / 1000 }))
            }
        }
        return out
    }

    private static func status(_ s: String?) -> TestStatus {
        switch s {
        case "passed": return .passed
        case "failed": return .failed
        case "pending", "skipped", "todo", "disabled": return .skipped
        default: return .unknown
        }
    }

    // MARK: pytest (JUnit XML)

    static func parseJUnit(
        _ data: Data, root: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [TestCaseResult] {
        let delegate = JUnitDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.cases.map { c in
            var file = ""
            var scope: [String] = []
            let parts = c.classname.split(separator: ".").map(String.init)
            var matched = false
            if !parts.isEmpty {
                for i in stride(from: parts.count, through: 1, by: -1) {
                    let rel = parts[0..<i].joined(separator: "/") + ".py"
                    if fileExists(root.appendingPathComponent(rel).path) {
                        file = root.appendingPathComponent(rel).path
                        scope = Array(parts[i...])
                        matched = true
                        break
                    }
                }
            }
            if !matched { scope = parts }
            let full = (scope + [c.name]).joined(separator: "::")
            return TestCaseResult(filePath: file, fullName: full, title: c.name, status: c.status,
                                  message: c.message.isEmpty ? nil : stripANSI(c.message), duration: c.time)
        }
    }

    private final class JUnitDelegate: NSObject, XMLParserDelegate {
        struct Case { var classname = ""; var name = ""; var time: Double?; var status = TestStatus.passed; var message = "" }
        var cases: [Case] = []
        private var current: Case?
        private var capturing = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String]) {
            switch name {
            case "testcase":
                current = Case(classname: a["classname"] ?? "", name: a["name"] ?? "", time: a["time"].flatMap(Double.init))
            case "failure", "error":
                current?.status = .failed
                current?.message = a["message"] ?? ""
                capturing = true
            case "skipped":
                current?.status = .skipped
                current?.message = a["message"] ?? ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing, current != nil, let existing = current?.message, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                current?.message = existing.isEmpty ? string : existing + "\n" + string
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "failure" || name == "error" { capturing = false }
            if name == "testcase", let c = current { cases.append(c); current = nil }
        }
    }

    // MARK: swift test

    static func parseSwiftTest(_ output: String) -> [TestCaseResult] {
        var order: [String] = []
        var byName: [String: TestCaseResult] = [:]
        func upsert(_ name: String, _ build: (inout TestCaseResult) -> Void) {
            if byName[name] == nil {
                byName[name] = TestCaseResult(filePath: "", fullName: name, title: name, status: .unknown)
                order.append(name)
            }
            build(&byName[name]!)
        }
        let caseRe = try? NSRegularExpression(pattern: #"^Test Case '([^']+)' (passed|failed|skipped)(?: \(([\d.]+) seconds\))?"#)
        let xcFailRe = try? NSRegularExpression(pattern: #"^(.+?):(\d+): error: (?:-\[([\w.]+) (\w+)\]|([\w.]+)) : (.*)$"#)
        let stResultRe = try? NSRegularExpression(pattern: #"^[✔✘↓] Test (.+?) (passed|failed|skipped)(?: after ([\d.]+) seconds)?"#)
        let stIssueRe = try? NSRegularExpression(pattern: #"^✘ Test (.+?) recorded an issue at (.+?):(\d+):\d+: (.*)$"#)

        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if let m = groups(caseRe, line) {
                let name = xcName(m[0])
                upsert(name) {
                    $0.status = m[1] == "passed" ? .passed : (m[1] == "failed" ? .failed : .skipped)
                    $0.duration = Double(m[2])
                }
            } else if let m = groups(xcFailRe, line) {
                let name = m[2].isEmpty ? xcName(m[4]) : xcName("-[\(m[2]) \(m[3])]")
                let text = "\(m[0]):\(m[1]): \(m[5])"
                upsert(name) {
                    $0.status = .failed
                    $0.message = ($0.message.map { $0 + "\n" } ?? "") + text
                }
            } else if let m = groups(stIssueRe, line) {
                upsert(m[0]) {
                    $0.status = .failed
                    $0.message = ($0.message.map { $0 + "\n" } ?? "") + "\(m[1]):\(m[2]): \(m[3])"
                }
            } else if let m = groups(stResultRe, line) {
                upsert(m[0]) {
                    $0.status = m[1] == "passed" ? .passed : (m[1] == "failed" ? .failed : .skipped)
                    $0.duration = Double(m[2])
                }
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// "-[Mod.Class test]" / "Mod.Class.test" / "Class.test" -> "Class/test".
    static func xcName(_ raw: String) -> String {
        if raw.hasPrefix("-["), raw.hasSuffix("]") {
            let inner = raw.dropFirst(2).dropLast()
            let pieces = inner.split(separator: " ")
            if pieces.count == 2 {
                let cls = pieces[0].split(separator: ".").last.map(String.init) ?? String(pieces[0])
                return cls + "/" + pieces[1]
            }
            return String(inner)
        }
        let parts = raw.split(separator: ".").map(String.init)
        if parts.count >= 2 { return parts[parts.count - 2] + "/" + parts[parts.count - 1] }
        return raw
    }

    private static func groups(_ re: NSRegularExpression?, _ line: String) -> [String]? {
        guard let re, let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
    }
}
