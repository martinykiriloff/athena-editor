// TaskServiceTests.swift
// Athena — tasks.json JSONC parsing, ${variable} substitution, dependsOn ordering, matchers.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

@Suite("tasks.json")
struct TaskServiceTests {

    private let sample = """
    {
      // VS Code allows comments here
      "version": "2.0.0",
      "tasks": [
        {
          "label": "build", /* block */ "type": "shell", "command": "npm",
          "args": ["run", "build", "--url=http://x//y",],
          "options": { "cwd": "${workspaceFolder}/web" },
          "group": { "kind": "build", "isDefault": true },
          "problemMatcher": ["$tsc", "$unknown"],
        },
        { "label": "lint", "type": "process", "command": "eslint", "args": [{ "value": "src" }], "group": "test" },
        { "label": "all", "dependsOn": ["lint", "build"], "dependsOrder": "sequence" },
      ]
    }
    """

    @Test func parsesJSONCWithCommentsAndTrailingCommas() throws {
        let tasks = try TaskService.parse(sample)
        #expect(tasks.map(\.label) == ["build", "lint", "all"])
        let build = tasks[0]
        #expect(build.args == ["run", "build", "--url=http://x//y"])
        #expect(build.cwd == "${workspaceFolder}/web")
        #expect(build.group == .build && build.isDefaultGroup)
        #expect(build.problemMatchers == [.tsc])
        #expect(tasks[1].kind == .process && tasks[1].args == ["src"] && tasks[1].group == .test)
        #expect(tasks[2].dependsOn == ["lint", "build"] && tasks[2].dependsSequence)
    }

    @Test func malformedThrows() {
        #expect(throws: TaskError.self) { try TaskService.parse("[1,2]") }
        #expect(throws: TaskError.self) { try TaskService.parse("{ nope") }
    }

    @Test func substitutesVariables() {
        let ctx = TaskVariableContext(workspaceFolder: "/w/app", activeFile: "/w/app/src/a.ts",
                                      environment: ["FOO": "bar"], home: "/Users/me")
        func sub(_ s: String) -> String { TaskService.substitute(s, context: ctx) }
        #expect(sub("${workspaceFolder}/dist") == "/w/app/dist")
        #expect(sub("${workspaceFolderBasename}") == "app")
        #expect(sub("${file}|${fileBasename}|${fileBasenameNoExtension}|${fileExtname}|${fileDirname}")
                == "/w/app/src/a.ts|a.ts|a|.ts|/w/app/src")
        #expect(sub("${env:FOO}-${env:MISSING}-") == "bar--")
        #expect(sub("${userHome}") == "/Users/me")
        #expect(sub("${unknown} ${workspaceFolder}") == "${unknown} /w/app")
        var noFile = ctx
        noFile.activeFile = nil
        #expect(TaskService.substitute("${file}", context: noFile) == "${file}")
    }

    @Test func dependenciesRunFirstAndOnce() throws {
        let tasks = try TaskService.parse(sample)
        #expect(try TaskService.executionPlan(for: "all", in: tasks).map(\.label) == ["lint", "build"])
        #expect(try TaskService.executionPlan(for: "build", in: tasks).map(\.label) == ["build"])

        let diamond = [
            TaskDefinition(label: "a", command: "a", dependsOn: ["b", "c"]),
            TaskDefinition(label: "b", command: "b", dependsOn: ["d"]),
            TaskDefinition(label: "c", command: "c", dependsOn: ["d"]),
            TaskDefinition(label: "d", command: "d"),
        ]
        #expect(try TaskService.executionPlan(for: "a", in: diamond).map(\.label) == ["d", "b", "c", "a"])
    }

    @Test func cyclesAndUnknownDependenciesThrow() {
        let cyc = [TaskDefinition(label: "a", command: "a", dependsOn: ["b"]),
                   TaskDefinition(label: "b", command: "b", dependsOn: ["a"])]
        #expect(throws: TaskError.dependencyCycle(["a", "b", "a"])) {
            try TaskService.executionPlan(for: "a", in: cyc)
        }
        #expect(throws: TaskError.unknownTask("zzz")) {
            try TaskService.executionPlan(for: "zzz", in: cyc)
        }
    }

    @Test func tscMatcher() {
        let out = "src/a.ts(12,5): error TS2322: Type 'x' is not assignable.\nnoise\nb.ts(1,1): warning TS6133: unused"
        let d = TaskService.problems(in: out, matchers: [.tsc], directory: URL(fileURLWithPath: "/w"))
        #expect(d.count == 2)
        #expect(d[0].fileURL.path == "/w/src/a.ts" && d[0].line == 12 && d[0].column == 5 && d[0].severity == .error)
        #expect(d[1].severity == .warning)
    }

    @Test func eslintStylishMatcher() {
        let out = "/w/src/a.js\n  3:10  error  'x' is defined but never used  no-unused-vars\n  4:1  warning  Missing semicolon  semi\n\n2 problems\n"
        let d = TaskService.problems(in: out, matchers: [.eslintStylish], directory: URL(fileURLWithPath: "/w"))
        #expect(d.count == 2)
        #expect(d[0].fileURL.path == "/w/src/a.js" && d[0].line == 3 && d[0].column == 10)
        #expect(d[0].message == "'x' is defined but never used")
        #expect(d[1].severity == .warning)
    }

    @Test func runStreamsOutputAndReturnsStatus() async throws {
        let service = TaskService()
        let ctx = TaskVariableContext(workspaceFolder: NSTemporaryDirectory())
        let box = OutputBox()
        let task = TaskDefinition(label: "t", command: "echo", args: ["hello world", "${workspaceFolderBasename}"])
        let status = try await service.run(task, context: ctx) { box.append($0) }
        #expect(status == 0)
        #expect(box.text.hasPrefix("hello world "))
        let fail = TaskDefinition(label: "f", command: "exit 3")
        let failStatus = try await service.run(fail, context: ctx) { _ in }
        #expect(failStatus == 3)
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ s: String) { lock.lock(); value += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}
