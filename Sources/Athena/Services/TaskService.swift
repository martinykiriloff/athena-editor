// TaskService.swift
// Athena — parses .vscode/tasks.json, resolves dependsOn, runs tasks, matches problems.
// Swift 6, strict concurrency.

import Foundation

actor TaskService {

    private var running: [String: Process] = [:]

    // MARK: - Loading

    /// Tasks from `<workspace>/.vscode/tasks.json`. A missing file is not an
    /// error (no tasks); an unreadable or malformed one throws.
    func loadTasks(in workspace: URL) throws -> [TaskDefinition] {
        let url = workspace.appendingPathComponent(".vscode/tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try Self.parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Parsing

    /// Reuses the theme importer's JSONC cleanup (comments, trailing commas)
    /// — the same leniency VS Code gives tasks.json.
    nonisolated static func parse(_ text: String) throws -> [TaskDefinition] {
        let cleaned = VSCodeThemeImporter.stripJSONCArtifacts(text)
        guard let root = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any] else {
            throw TaskError.malformed("not a JSON object")
        }
        guard let raw = root["tasks"] as? [[String: Any]] else { return [] }

        // Top-level command/type are the defaults for every task.
        let topCommand = root["command"] as? String
        let topType = root["type"] as? String

        var result: [TaskDefinition] = []
        for entry in raw {
            let label = (entry["label"] as? String) ?? (entry["taskName"] as? String)
            guard let label, !label.isEmpty else { continue }

            let dependsOn: [String]
            if let one = entry["dependsOn"] as? String {
                dependsOn = [one]
            } else if let many = entry["dependsOn"] as? [Any] {
                dependsOn = many.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["task"] as? String) }
            } else {
                dependsOn = []
            }

            let command = (entry["command"] as? String) ?? topCommand ?? ""
            // A task that only aggregates others needs no command.
            if command.isEmpty && dependsOn.isEmpty { continue }

            let options = entry["options"] as? [String: Any]
            let typeString = (entry["type"] as? String) ?? topType ?? "shell"

            var group: TaskDefinition.Group = .none
            var isDefault = false
            if let g = entry["group"] as? String {
                group = TaskDefinition.Group(rawValue: g) ?? .none
            } else if let g = entry["group"] as? [String: Any] {
                group = (g["kind"] as? String).flatMap(TaskDefinition.Group.init(rawValue:)) ?? .none
                isDefault = (g["isDefault"] as? Bool) ?? false
            }

            let matcherNames: [String]
            if let one = entry["problemMatcher"] as? String {
                matcherNames = [one]
            } else if let many = entry["problemMatcher"] as? [Any] {
                matcherNames = many.compactMap { $0 as? String }
            } else {
                matcherNames = []
            }

            result.append(TaskDefinition(
                label: label,
                kind: TaskDefinition.Kind(rawValue: typeString) ?? .shell,
                command: command,
                args: parseArgs(entry["args"]),
                cwd: options?["cwd"] as? String,
                env: (options?["env"] as? [String: String]) ?? [:],
                group: group,
                isDefaultGroup: isDefault,
                dependsOn: dependsOn,
                dependsSequence: (entry["dependsOrder"] as? String) == "sequence",
                isBackground: (entry["isBackground"] as? Bool) ?? false,
                problemMatchers: matcherNames.compactMap(TaskProblemMatcher.init(rawValue:)),
                detail: entry["detail"] as? String
            ))
        }
        return result
    }

    /// Args are strings or `{ "value": …, "quoting": … }` objects.
    private nonisolated static func parseArgs(_ any: Any?) -> [String] {
        guard let list = any as? [Any] else { return [] }
        return list.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["value"] as? String) }
    }

    // MARK: - Variables

    /// Expands `${workspaceFolder}`, `${workspaceFolderBasename}`, `${cwd}`,
    /// `${file}`, `${fileDirname}`, `${fileBasename}`, `${fileBasenameNoExtension}`,
    /// `${fileExtname}`, `${userHome}`, `${env:NAME}`. Unknown variables and
    /// file variables with no open file are left as written.
    nonisolated static func substitute(_ text: String, context: TaskVariableContext) -> String {
        guard text.contains("${"),
              let regex = try? NSRegularExpression(pattern: "\\$\\{([^}]+)\\}") else { return text }
        var out = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text) else { continue }
            out += text[cursor..<whole.lowerBound]
            out += value(of: String(text[nameRange]), context: context) ?? String(text[whole])
            cursor = whole.upperBound
        }
        out += text[cursor...]
        return out
    }

    private nonisolated static func value(of name: String, context: TaskVariableContext) -> String? {
        if name.hasPrefix("env:") { return context.environment[String(name.dropFirst(4))] ?? "" }
        let file = context.activeFile.map { URL(fileURLWithPath: $0) }
        switch name {
        case "workspaceFolder", "cwd": return context.workspaceFolder
        case "workspaceFolderBasename": return URL(fileURLWithPath: context.workspaceFolder).lastPathComponent
        case "userHome": return context.home
        case "file": return context.activeFile
        case "fileDirname": return file?.deletingLastPathComponent().path
        case "fileBasename": return file?.lastPathComponent
        case "fileBasenameNoExtension": return file?.deletingPathExtension().lastPathComponent
        case "fileExtname": return file.map { $0.pathExtension.isEmpty ? "" : "." + $0.pathExtension }
        default: return nil
        }
    }

    // MARK: - Dependencies

    /// The tasks to run for `label`, dependencies first, each once. Deps run
    /// one after another (a `parallel` dependsOrder is run sequentially).
    nonisolated static func executionPlan(for label: String, in tasks: [TaskDefinition]) throws -> [TaskDefinition] {
        let byLabel = Dictionary(tasks.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        var plan: [TaskDefinition] = []
        var done: Set<String> = []

        func visit(_ name: String, path: [String]) throws {
            if path.contains(name) { throw TaskError.dependencyCycle(path + [name]) }
            guard let task = byLabel[name] else { throw TaskError.unknownTask(name) }
            if done.contains(name) { return }
            for dep in task.dependsOn { try visit(dep, path: path + [name]) }
            done.insert(name)
            if !task.command.isEmpty { plan.append(task) }
        }
        try visit(label, path: [])
        return plan
    }

    /// The schedule for `label`: dependencies in parallel (VS Code's default)
    /// or in sequence when `dependsOrder` is "sequence", then the task itself.
    /// Shared dependencies appear in several places; the runner runs each once.
    nonisolated static func executionTree(for label: String, in tasks: [TaskDefinition]) throws -> TaskPlan {
        let byLabel = Dictionary(tasks.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        func node(_ name: String, path: [String]) throws -> TaskPlan {
            if path.contains(name) { throw TaskError.dependencyCycle(path + [name]) }
            guard let task = byLabel[name] else { throw TaskError.unknownTask(name) }
            let deps = try task.dependsOn.map { try node($0, path: path + [name]) }
            let own: [TaskPlan] = task.command.isEmpty ? [] : [.run(task)]
            if deps.isEmpty { return own.first ?? .sequence([]) }
            if task.dependsSequence { return .sequence(deps + own) }
            return .sequence([deps.count == 1 ? deps[0] : .parallel(deps)] + own)
        }
        return try node(label, path: [])
    }

    /// For a watcher's output: the text after the last "compilation starting"
    /// marker, so a re-compile replaces rather than duplicates old problems.
    nonisolated static func backgroundWindow(_ buffer: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "Starting (incremental )?compilation|File change detected"),
              let last = re.matches(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)).last,
              let r = Range(last.range, in: buffer) else { return buffer }
        return String(buffer[r.lowerBound...])
    }

    // MARK: - Running

    /// Runs one task, streaming combined stdout/stderr to `onOutput`, and
    /// returns its exit status.
    func run(
        _ task: TaskDefinition,
        context: TaskVariableContext,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let command = Self.substitute(task.command, context: context)
        let args = task.args.map { Self.substitute($0, context: context) }

        let line: String
        switch task.kind {
        case .shell:
            line = ([command] + args.map(Self.shellQuote)).joined(separator: " ")
        case .process:
            line = "exec " + ([command] + args).map(Self.shellQuote).joined(separator: " ")
        }

        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", line]
        let cwd = task.cwd.map { Self.substitute($0, context: context) } ?? context.workspaceFolder
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        if !task.env.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in task.env { env[key] = Self.substitute(value, context: context) }
            process.environment = env
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading

        // Installed before `run()` — a handler set after a fast exit never fires.
        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        running[task.label] = process
        defer { running[task.label] = nil }

        await Self.drain(handle, onChunk: onOutput)
        var status: Int32 = 0
        for await code in termination { status = code }
        return status
    }

    func stopAll() {
        for process in running.values { process.terminate() }
    }

    /// Blocking reads on a GCD queue (not the cooperative pool), bridged with
    /// a continuation; each chunk is forwarded as it arrives and the loop ends
    /// at EOF, so nothing is left in the pipe when the task exits.
    private static func drain(_ handle: FileHandle, onChunk: @escaping @Sendable (String) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    onChunk(String(decoding: data, as: UTF8.self))
                }
                continuation.resume()
            }
        }
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:,@%+".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Problem matching

    /// Parses task output with the task's matchers. Relative file names are
    /// resolved against `directory`.
    nonisolated static func problems(
        in output: String,
        matchers: [TaskProblemMatcher],
        directory: URL
    ) -> [Diagnostic] {
        var found: [Diagnostic] = []
        for matcher in matchers {
            switch matcher {
            case .tsc:
                // file(line,col): error TS1234: message
                let re = try? NSRegularExpression(
                    pattern: #"^(.+?)\((\d+),(\d+)\):\s+(error|warning)\s+TS\d+:\s+(.*)$"#,
                    options: .anchorsMatchLines)
                for m in captures(re, output) {
                    guard let line = Int(m[1]), let col = Int(m[2]) else { continue }
                    found.append(Diagnostic(fileURL: resolve(m[0], directory), line: line, column: col,
                                            message: m[4], severity: m[3] == "warning" ? .warning : .error))
                }
            case .eslintStylish:
                // A bare path line, then "  line:col  severity  message  rule" lines.
                var file: URL?
                let item = try? NSRegularExpression(
                    pattern: #"^\s+(\d+):(\d+)\s+(error|warning)\s+(.*?)(?:\s{2,}\S+)?$"#)
                for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = String(raw)
                    if let hit = captures(item, line).first, let file, let l = Int(hit[0]), let c = Int(hit[1]) {
                        found.append(Diagnostic(fileURL: file, line: l, column: c, message: hit[3],
                                                severity: hit[2] == "warning" ? .warning : .error))
                    } else if line.hasPrefix("/") {
                        file = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        return found
    }

    private nonisolated static func resolve(_ path: String, _ directory: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path).standardizedFileURL
    }

    /// Capture groups (without group 0) of every match.
    private nonisolated static func captures(_ re: NSRegularExpression?, _ text: String) -> [[String]] {
        guard let re else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }
}
