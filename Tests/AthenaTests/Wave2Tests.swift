// Wave2Tests.swift
// Athena — test runner parsing/discovery, task scheduling, lint output parsers, npm audit, diagnostics merge.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

@Suite("Test runner")
struct TestRunnerTests {

    @Test func detectsFrameworks() {
        let pkg = #"{"devDependencies":{"jest":"^29","vitest":"^1"}}"#
        #expect(TestDiscovery.detectFrameworks(packageJSON: pkg, rootFiles: ["Package.swift", "pytest.ini"],
                                               pyproject: nil, toxIni: nil, setupCfg: nil)
                == [.vitest, .jest, .pytest, .swiftTest])
        #expect(TestDiscovery.detectFrameworks(packageJSON: nil, rootFiles: [],
                                               pyproject: "[tool.pytest.ini_options]", toxIni: nil, setupCfg: nil) == [.pytest])
        #expect(TestDiscovery.detectFrameworks(packageJSON: #"{"dependencies":{"react":"1"}}"#, rootFiles: [],
                                               pyproject: nil, toxIni: nil, setupCfg: nil).isEmpty)
    }

    @Test func jsDeclarationsNestFullNames() {
        let src = """
        describe('math', () => {
          it('adds', () => {})
          describe('nested', () => {
            test.skip("subtracts", () => {})
          })
        })
        it.each([1])('ignored %s', () => {})
        """
        let d = TestDiscovery.declarations(in: src, framework: .jest)
        #expect(d.map(\.fullName) == ["math", "math adds", "math nested", "math nested subtracts"])
        #expect(d.map(\.line) == [1, 2, 3, 4])
        #expect(d.map(\.isSuite) == [true, false, true, false])
        #expect(d[3].depth == 2)
    }

    @Test func pythonDeclarations() {
        let src = "def test_top():\n    pass\n\nclass TestCalc:\n    def test_add(self):\n        pass\n    async def test_sub(self):\n        pass\n\ndef helper():\n    pass\n"
        let d = TestDiscovery.declarations(in: src, framework: .pytest)
        #expect(d.map(\.fullName) == ["test_top", "TestCalc", "TestCalc::test_add", "TestCalc::test_sub"])
    }

    @Test func swiftDeclarations() {
        let src = """
        final class CalcTests: XCTestCase {
            func testAdd() {}
            func helper() {}
        }
        @Suite struct Math {
            @Test func multiplies() {}
            @Test
            func divides() {}
        }
        """
        let d = TestDiscovery.declarations(in: src, framework: .swiftTest)
        #expect(d.map(\.fullName) == ["CalcTests", "CalcTests/testAdd", "Math", "Math/multiplies()", "Math/divides()"])
    }

    @Test func frameworkForPath() {
        let all: [TestFramework] = [.jest, .pytest, .swiftTest]
        #expect(TestDiscovery.framework(forRelativePath: "src/a.test.ts", detected: all) == .jest)
        #expect(TestDiscovery.framework(forRelativePath: "src/a.ts", detected: all) == nil)
        #expect(TestDiscovery.framework(forRelativePath: "tests/test_x.py", detected: all) == .pytest)
        #expect(TestDiscovery.framework(forRelativePath: "Tests/AthenaTests/A.swift", detected: all) == .swiftTest)
        #expect(TestDiscovery.framework(forRelativePath: "a.spec.js", detected: [.vitest, .jest]) == .vitest)
    }

    @Test func parsesJestJSON() {
        let json = """
        {"testResults":[
          {"name":"/w/a.test.js","status":"failed","assertionResults":[
            {"ancestorTitles":["math"],"fullName":"math adds","title":"adds","status":"passed","duration":4,"failureMessages":[]},
            {"ancestorTitles":["math"],"fullName":"math subs","title":"subs","status":"failed","failureMessages":["\\u001b[31mExpected 1\\u001b[39m"]},
            {"ancestorTitles":[],"fullName":"todo","title":"todo","status":"todo","failureMessages":[]}]},
          {"name":"/w/b.test.js","status":"failed","message":"SyntaxError","assertionResults":[]}
        ]}
        """
        let r = TestOutputParser.parseJestJSON(Data(json.utf8))
        #expect(r.count == 4)
        #expect(r[0].status == .passed && r[0].duration == 0.004 && r[0].filePath == "/w/a.test.js")
        #expect(r[1].status == .failed && r[1].message == "Expected 1")
        #expect(r[2].status == .skipped)
        #expect(r[3].status == .failed && r[3].message == "SyntaxError")
        #expect(TestOutputParser.parseJestJSON(Data("nope".utf8)).isEmpty)
    }

    @Test func parsesJUnit() {
        let xml = """
        <?xml version="1.0"?><testsuites><testsuite name="pytest">
        <testcase classname="tests.test_calc.TestCalc" name="test_add" time="0.01"/>
        <testcase classname="tests.test_calc.TestCalc" name="test_sub" time="0.02"><failure message="assert 1 == 2">trace here</failure></testcase>
        <testcase classname="tests.test_calc" name="test_skip" time="0"><skipped message="why"/></testcase>
        </testsuite></testsuites>
        """
        let root = URL(fileURLWithPath: "/w")
        let r = TestOutputParser.parseJUnit(Data(xml.utf8), root: root) { $0 == "/w/tests/test_calc.py" }
        #expect(r.map(\.fullName) == ["TestCalc::test_add", "TestCalc::test_sub", "test_skip"])
        #expect(r.map(\.status) == [.passed, .failed, .skipped])
        #expect(r[0].filePath == "/w/tests/test_calc.py")
        #expect(r[1].message?.contains("assert 1 == 2") == true)
    }

    @Test func parsesSwiftTestOutput() {
        let out = """
        Test Case '-[AthenaTests.CalcTests testAdd]' started.
        Test Case '-[AthenaTests.CalcTests testAdd]' passed (0.001 seconds).
        /w/Tests/CalcTests.swift:12: error: -[AthenaTests.CalcTests testSub] : XCTAssertEqual failed: ("1") is not equal to ("2")
        Test Case '-[AthenaTests.CalcTests testSub]' failed (0.002 seconds).
        Test Case 'CalcTests.testLinux' passed (0.5 seconds)
        ✔ Test multiplies() passed after 0.001 seconds.
        ✘ Test divides() recorded an issue at Math.swift:9:5: Expectation failed: (a → 1) == (b → 2)
        ✘ Test divides() failed after 0.002 seconds with 1 issue.
        """
        let r = TestOutputParser.parseSwiftTest(out)
        #expect(r.map(\.fullName) == ["CalcTests/testAdd", "CalcTests/testSub", "CalcTests/testLinux", "multiplies()", "divides()"])
        #expect(r.map(\.status) == [.passed, .failed, .passed, .passed, .failed])
        #expect(r[1].message?.contains("CalcTests.swift:12") == true)
        #expect(r[4].message?.contains("Math.swift:9") == true)
    }

    @Test func buildsCommands() {
        let root = URL(fileURLWithPath: "/w")
        let exists: (String) -> Bool = { $0.hasSuffix("/jest") || $0 == "/usr/bin/swift" }
        let jest = TestCommand.invocation(framework: .jest, scope: .test(path: "/w/a.test.js", fullName: "math (adds)"),
                                          root: root, reportPath: "/tmp/r.json", fileExists: exists)
        #expect(jest?.executable.path == "/w/node_modules/.bin/jest")
        #expect(jest?.arguments == ["--json", "--outputFile=/tmp/r.json", "--runTestsByPath", "/w/a.test.js",
                                    "-t", "^math \\(adds\\)$"])
        #expect(TestCommand.invocation(framework: .vitest, scope: .all, root: root, reportPath: "x", fileExists: exists) == nil)
        let py = TestCommand.invocation(framework: .pytest, scope: .test(path: "/w/t.py", fullName: "TestA::test_b"),
                                        root: root, reportPath: "/tmp/r.xml", fileExists: exists)
        #expect(py?.arguments.suffix(1) == ["/w/t.py::TestA::test_b"])
        let failed = [TestCaseResult(filePath: "/w/a.test.js", fullName: "x", title: "x", status: .failed),
                      TestCaseResult(filePath: "/w/a.test.js", fullName: "y", title: "y", status: .failed)]
        let again = TestCommand.invocation(framework: .jest, scope: .failed(failed), root: root, reportPath: "r", fileExists: exists)
        #expect(again?.arguments.suffix(2) == ["-t", "^(x|y)$"])
        let sw = TestCommand.invocation(framework: .swiftTest, scope: .test(path: "", fullName: "A/testB"),
                                        root: root, reportPath: "", fileExists: exists)
        #expect(sw?.arguments == ["test", "--filter", "A\\/testB$"])
    }

    @MainActor @Test func runningKeysCoverScope() {
        let node = TestFileNode(path: "/w/a.test.js", framework: .jest, declarations: [
            TestDeclaration(line: 1, title: "a", fullName: "a", isSuite: false),
            TestDeclaration(line: 2, title: "b", fullName: "b", isSuite: false)])
        #expect(AppState.keys(in: .all, files: [node]).count == 2)
        #expect(AppState.keys(in: .test(path: "/w/a.test.js", fullName: "a"), files: [node]) == [TestCenter.key("/w/a.test.js", "a")])
    }
}

@Suite("Tasks: scheduling")
struct TaskSchedulingTests {

    @Test func parallelIsDefaultAndSequenceIsHonoured() throws {
        let tasks = [
            TaskDefinition(label: "all", command: "", dependsOn: ["a", "b"]),
            TaskDefinition(label: "seq", command: "", dependsOn: ["a", "b"], dependsSequence: true),
            TaskDefinition(label: "a", command: "a"),
            TaskDefinition(label: "b", command: "b", isBackground: true),
        ]
        let a = TaskDefinition(label: "a", command: "a")
        let b = TaskDefinition(label: "b", command: "b", isBackground: true)
        #expect(try TaskService.executionTree(for: "all", in: tasks) == .sequence([.parallel([.run(a), .run(b)])]))
        #expect(try TaskService.executionTree(for: "seq", in: tasks) == .sequence([.run(a), .run(b)]))
        #expect(try TaskService.executionTree(for: "all", in: tasks).containsParallel)
        #expect(!(try TaskService.executionTree(for: "seq", in: tasks).containsParallel))
        #expect(throws: TaskError.self) { try TaskService.executionTree(for: "nope", in: tasks) }
    }

    @Test func treeDetectsCycles() {
        let cyc = [TaskDefinition(label: "a", command: "a", dependsOn: ["b"]),
                   TaskDefinition(label: "b", command: "b", dependsOn: ["a"])]
        #expect(throws: TaskError.dependencyCycle(["a", "b", "a"])) { try TaskService.executionTree(for: "a", in: cyc) }
    }

    @Test func parsesIsBackground() throws {
        let t = try TaskService.parse(#"{"tasks":[{"label":"w","command":"tsc","args":["-w"],"isBackground":true}]}"#)
        #expect(t[0].isBackground)
    }

    @Test func backgroundWindowKeepsLatestCompilation() {
        let buf = "Starting compilation in watch mode...\na.ts(1,1): error TS1: old\nFile change detected. Starting incremental compilation...\nb.ts(2,2): error TS2: new\n"
        let window = TaskService.backgroundWindow(buf)
        #expect(!window.contains("old") && window.contains("new"))
        #expect(TaskService.backgroundWindow("plain") == "plain")
    }

    @Test func prefixesEachLineOnce() {
        var p = LinePrefixer(prefix: "[x] ")
        #expect(p.feed("ab") + p.feed("c\nd\n") == "[x] abc\n[x] d\n")
        var none = LinePrefixer(prefix: "")
        #expect(none.feed("z") == "z")
    }

    @Test func compoundsParseAndResolve() {
        let json: [String: Any] = ["compounds": [["name": "All", "configurations": ["api", ["name": "web"], "ghost"]]]]
        let compounds = LaunchConfig.compounds(from: json)
        #expect(compounds.count == 1 && compounds[0].compoundMembers == ["api", "web", "ghost"])
        let configs = [LaunchConfig(type: "node-cdp", request: "launch", name: "api", program: "a.js"),
                       LaunchConfig(type: "chrome", request: "launch", name: "web", program: ""), compounds[0]]
        let r = AppState.resolveCompound(members: compounds[0].compoundMembers ?? [], among: configs)
        #expect(r.found.map(\.name) == ["api", "web"] && r.missing == ["ghost"])
        #expect(LaunchConfig.compounds(from: ["compounds": [["name": "Empty", "configurations": []]]]).isEmpty)
    }
}

@Suite("Lint parsers")
struct LintParserTests {
    let root = URL(fileURLWithPath: "/w")

    @Test func eslintJSON() {
        let json = """
        [{"filePath":"/w/src/a.js","messages":[
          {"ruleId":"no-unused-vars","severity":2,"message":"'x' is defined but never used.","line":3,"column":7},
          {"ruleId":null,"severity":2,"message":"Parsing error: Unexpected token","line":1,"column":1},
          {"ruleId":"semi","severity":1,"message":"Missing semicolon.","line":4,"column":2},
          {"ruleId":null,"severity":1,"message":"File ignored because of a matching ignore pattern."}]}]
        """
        let d = LintOutputParser.parseESLintJSON(Data(json.utf8))
        #expect(d.count == 3)
        #expect(d[0].line == 3 && d[0].column == 7 && d[0].severity == .error && d[0].source == "eslint")
        #expect(d[0].message.hasSuffix("(no-unused-vars)"))
        #expect(d[2].severity == .warning)
    }

    @Test func biomeGitHubReporter() {
        let out = """
        ::error title=lint/correctness/noUnusedImports,file=src/a.ts,line=1,endLine=1,col=10,endColumn=13::This import is unused.
        ::warning title=lint/style/noVar,file=src/b.ts,line=5,endLine=5,col=1,endColumn=4::Use let or const.
        some other line
        """
        let d = LintOutputParser.parseBiomeGitHub(out, directory: root)
        #expect(d.count == 2)
        #expect(d[0].fileURL.path == "/w/src/a.ts" && d[0].line == 1 && d[0].column == 10 && d[0].severity == .error)
        #expect(d[0].message == "This import is unused. (lint/correctness/noUnusedImports)")
        #expect(d[1].severity == .warning && d[1].source == "biome")
    }

    @Test func tscOutput() {
        let out = "src/a.ts(12,5): error TS2322: Type 'x' is not assignable.\nsrc/b.ts(1,8): error TS6133: 'fs' is declared but its value is never read.\nFound 2 errors.\n"
        let d = LintOutputParser.parseTSC(out, directory: root)
        #expect(d.count == 2)
        #expect(d[0].fileURL.path == "/w/src/a.ts" && d[0].message == "Type 'x' is not assignable. (TS2322)")
        #expect(d[1].message.contains("TS6133") && d[1].source == "tsc")
    }

    @Test func npmAuditV7() throws {
        let json = """
        {"auditReportVersion":2,"vulnerabilities":{
          "lodash":{"name":"lodash","severity":"high","isDirect":true,"range":"<4.17.21",
            "via":[{"title":"Prototype Pollution","url":"https://x/1","severity":"high"}],"fixAvailable":true},
          "minimist":{"name":"minimist","severity":"critical","isDirect":false,"range":"<1.2.6","via":["dep"],"fixAvailable":{"name":"a","version":"2"}}},
          "metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":1,"total":2}}}
        """
        let r = try #require(NPMAuditParser.parse(Data(json.utf8)))
        #expect(r.vulnerabilities.map(\.name) == ["minimist", "lodash"])
        #expect(r.vulnerabilities[1].title == "Prototype Pollution" && r.vulnerabilities[1].isDirect)
        #expect(r.vulnerabilities[0].fixAvailable && !r.vulnerabilities[0].isDirect)
        #expect(r.counts == ["critical": 1, "high": 1])
        let text = NPMAuditParser.render(r)
        #expect(text.contains("1 critical, 1 high") && text.contains("lodash"))
    }

    @Test func npmAuditV6AndEmpty() throws {
        let v6 = #"{"advisories":{"1":{"module_name":"x","severity":"low","title":"T","url":"u","vulnerable_versions":"<2"}}}"#
        #expect(try #require(NPMAuditParser.parse(Data(v6.utf8))).vulnerabilities.first?.name == "x")
        let clean = #"{"vulnerabilities":{},"metadata":{"vulnerabilities":{"total":0}}}"#
        let r = try #require(NPMAuditParser.parse(Data(clean.utf8)))
        #expect(NPMAuditParser.render(r).contains("No vulnerabilities"))
        #expect(NPMAuditParser.parse(Data("{\"error\":{}}".utf8)) == nil)
    }
}

@Suite("Diagnostics merge")
@MainActor
struct DiagnosticsMergeTests {

    @Test func externalFeedsSurviveLSPPublishes() {
        let state = AppState()
        let url = URL(fileURLWithPath: "/w/a.ts")
        state.diagnosticsCenter.feeds["eslint"] = [url: [Diagnostic(fileURL: url, line: 1, column: 1, message: "e", severity: .error, source: "eslint")]]
        state.setTaskDiagnostics(label: "build", [Diagnostic(fileURL: url, line: 2, column: 1, message: "t", severity: .warning)])
        // An LSP publish replaces only its own dictionary.
        state.diagnostics[url] = [Diagnostic(fileURL: url, line: 3, column: 1, message: "lsp", severity: .error)]
        state.diagnostics[url] = []
        let all = state.allDiagnostics(for: url)
        #expect(all.map(\.message).sorted() == ["e", "t"])
        #expect(all.first { $0.message == "t" }?.source == "task: build")
        #expect(state.mergedDiagnostics[url]?.count == 2)
        #expect(state.sortedDiagnostics.count == 2)
        state.setTaskDiagnostics(label: "build", [])
        #expect(state.allDiagnostics(for: url).count == 1)
        state.diagnosticsCenter.clearAll()
        #expect(state.mergedDiagnostics[url] == nil || state.mergedDiagnostics[url]?.isEmpty == true)
    }
}
