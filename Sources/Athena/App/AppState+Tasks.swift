// AppState+Tasks.swift
// Athena — .vscode/tasks.json: task state, "Run Task…" and running into the Output panel.
// Swift 6, strict concurrency.

import Foundation

// MARK: - TaskCenter

/// State for tasks.json support. A separate object (held by `AppState` as
/// `taskCenter`) because an extension can't add stored properties.
@Observable @MainActor
final class TaskCenter {
    var tasks: [TaskDefinition] = []
    var showPicker = false
    var runningLabel: String?
    /// Watcher (`isBackground`) tasks that are still alive.
    var backgroundLabels: Set<String> = []
    /// Jobs of the current run by label, so a shared dependency runs once.
    @ObservationIgnored var memo: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored let service = TaskService()
    @ObservationIgnored var runTask: Task<Void, Never>?
}

// MARK: - AppState

@MainActor
extension AppState {

    /// Re-reads `.vscode/tasks.json`. A malformed file is reported in the
    /// Output panel rather than silently ignored.
    func reloadTasks() async {
        guard let root = workspace?.rootURL else { taskCenter.tasks = []; return }
        do {
            taskCenter.tasks = try await taskCenter.service.loadTasks(in: root)
        } catch {
            taskCenter.tasks = []
            scriptOutput += "\n[tasks] \(error.localizedDescription)\n"
        }
    }

    /// Opens the "Run Task…" picker (reloading first so edits show up).
    func presentTaskPicker() {
        guard workspace != nil else { statusMessage = "Open a folder to run tasks."; return }
        Task {
            await reloadTasks()
            if taskCenter.tasks.isEmpty {
                statusMessage = "No tasks found in .vscode/tasks.json"
            } else {
                taskCenter.showPicker = true
            }
        }
    }

    /// Runs `label` and its dependencies (in parallel unless `dependsOrder`
    /// is "sequence"), streaming to the Output panel. Problems found by the
    /// tasks' matchers go to the Problems panel as a separate feed.
    func runWorkspaceTask(label: String) {
        guard let root = workspace?.rootURL else { return }
        guard taskCenter.runningLabel == nil else {
            statusMessage = "A task is already running: \(taskCenter.runningLabel ?? "")"
            return
        }
        let plan: TaskPlan
        do {
            plan = try TaskService.executionTree(for: label, in: taskCenter.tasks)
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        let env = TaskRunEnv(
            context: TaskVariableContext(
                workspaceFolder: root.path,
                activeFile: focusedTab?.fileURL?.path,
                environment: ProcessInfo.processInfo.environment),
            root: root,
            prefixLines: plan.containsParallel)
        showBottomPanel = true
        activeBottomPanel = .output
        let center = taskCenter
        center.runningLabel = label
        center.memo = [:]

        center.runTask = Task { [weak self] in
            guard let self else { return }
            let ok = await self.execute(plan, env: env)
            center.runningLabel = nil
            center.memo = [:]
            self.statusMessage = ok ? "Task finished: \(label)" : "Task failed: \(label)"
        }
    }

    /// Stops the running task chain and any background tasks.
    func stopWorkspaceTask() {
        taskCenter.runTask?.cancel()
        Task { await taskCenter.service.stopAll() }
    }

    // MARK: - Compound launch configurations

    /// The configs a compound names, in order, skipping unknown names and nested compounds.
    nonisolated static func resolveCompound(members: [String], among configs: [LaunchConfig]) -> (found: [LaunchConfig], missing: [String]) {
        var found: [LaunchConfig] = []
        var missing: [String] = []
        for name in members {
            if let c = configs.first(where: { $0.name == name && $0.compoundMembers == nil }) {
                found.append(c)
            } else {
                missing.append(name)
            }
        }
        return (found, missing)
    }

    /// Starts each member in order through the normal launch path. `DebugService`
    /// runs a single session, so while one is live later members are skipped
    /// with a notice rather than clobbering it.
    func startCompound(_ compound: LaunchConfig, members: [String]) async {
        let (found, missing) = Self.resolveCompound(members: members, among: launchConfigs)
        showBottomPanel = true
        activeBottomPanel = .debugConsole
        for name in missing { debugOutput += "[Athena] Compound \"\(compound.name)\": no configuration named \"\(name)\"\n" }
        for config in found {
            guard debugState == .idle || debugState == .stopped else {
                debugOutput += "[Athena] Compound \"\(compound.name)\": skipped \"\(config.name)\" — the debugger runs one session at a time\n"
                continue
            }
            await startDebugging(using: config)
        }
    }

    // MARK: - Scheduling

    private func execute(_ plan: TaskPlan, env: TaskRunEnv) async -> Bool {
        if Task.isCancelled { return false }
        switch plan {
        case .run(let task):
            return await runSingle(task, env: env)
        case .sequence(let steps):
            for step in steps {
                if !(await execute(step, env: env)) { return false }
            }
            return true
        case .parallel(let branches):
            // Unstructured jobs: every branch runs even if one fails, as in VS Code.
            let jobs = branches.map { branch in
                Task { @MainActor [self] in await self.execute(branch, env: env) }
            }
            var ok = true
            for job in jobs where !(await job.value) { ok = false }
            return ok
        }
    }

    /// A task shared by several branches runs once; later requesters await
    /// the same job.
    private func runSingle(_ task: TaskDefinition, env: TaskRunEnv) async -> Bool {
        let center = taskCenter
        if let existing = center.memo[task.label] { return await existing.value }
        let job = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return task.isBackground ? self.startBackground(task, env: env) : await self.runForeground(task, env: env)
        }
        center.memo[task.label] = job
        return await job.value
    }

    private func runForeground(_ task: TaskDefinition, env: TaskRunEnv) async -> Bool {
        let center = taskCenter
        scriptOutput += "\n> Executing task: \(task.label)\n"
        setTaskDiagnostics(label: task.label, [])
        let (chunks, sink) = AsyncStream<String>.makeStream()
        let prefix = env.prefixLines ? "[\(task.label)] " : ""
        let consumer = Task { @MainActor [weak self] () -> String in
            var captured = ""
            var prefixer = LinePrefixer(prefix: prefix)
            for await chunk in chunks {
                self?.scriptOutput += prefixer.feed(chunk)
                captured += chunk
            }
            return captured
        }
        let status: Int32
        do {
            status = try await center.service.run(task, context: env.context) { sink.yield($0) }
        } catch {
            sink.finish()
            _ = await consumer.value
            scriptOutput += "Error: \(error.localizedDescription)\n"
            return false
        }
        sink.finish()
        let captured = await consumer.value
        if !task.problemMatchers.isEmpty {
            let found = TaskService.problems(in: captured, matchers: task.problemMatchers, directory: env.root)
            setTaskDiagnostics(label: task.label, found)
            scriptOutput += "[tasks] \(found.count) problem\(found.count == 1 ? "" : "s") matched\n"
        }
        scriptOutput += "[Task \"\(task.label)\" exited with code \(status)]\n"
        return status == 0 && !Task.isCancelled
    }

    /// `isBackground` tasks (watchers) are started and not awaited; dependents
    /// proceed straight away. Their matchers re-run on every chunk over the
    /// output since the last compilation-start marker.
    private func startBackground(_ task: TaskDefinition, env: TaskRunEnv) -> Bool {
        let center = taskCenter
        guard !center.backgroundLabels.contains(task.label) else { return true }
        center.backgroundLabels.insert(task.label)
        scriptOutput += "\n> Started background task: \(task.label)\n"
        setTaskDiagnostics(label: task.label, [])
        let (chunks, sink) = AsyncStream<String>.makeStream()
        let prefix = "[\(task.label)] "
        Task { @MainActor [weak self] in
            let reader = Task { @MainActor [weak self] in
                var buffer = ""
                var prefixer = LinePrefixer(prefix: prefix)
                for await chunk in chunks {
                    guard let self else { continue }
                    self.scriptOutput += prefixer.feed(chunk)
                    guard !task.problemMatchers.isEmpty else { continue }
                    buffer = TaskService.backgroundWindow(String((buffer + chunk).suffix(200_000)))
                    self.setTaskDiagnostics(label: task.label, TaskService.problems(
                        in: buffer, matchers: task.problemMatchers, directory: env.root))
                }
            }
            _ = try? await center.service.run(task, context: env.context) { sink.yield($0) }
            sink.finish()
            await reader.value
            center.backgroundLabels.remove(task.label)
            self?.scriptOutput += "[Background task \"\(task.label)\" ended]\n"
        }
        return true
    }
}

// MARK: - Supporting types

struct TaskRunEnv: Sendable {
    var context: TaskVariableContext
    var root: URL
    /// Prefix each output line with `[label]` so parallel tasks stay readable.
    var prefixLines: Bool
}

/// Prefixes each complete line of streamed output; a partial trailing line
/// waits for its newline (the prefix is emitted once per line).
struct LinePrefixer {
    let prefix: String
    private var atLineStart = true

    init(prefix: String) { self.prefix = prefix }

    mutating func feed(_ chunk: String) -> String {
        guard !prefix.isEmpty else { return chunk }
        var out = ""
        for ch in chunk {
            if atLineStart { out += prefix; atLineStart = false }
            out.append(ch)
            if ch == "\n" { atLineStart = true }
        }
        return out
    }
}
