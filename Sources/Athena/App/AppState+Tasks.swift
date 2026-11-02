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

    /// Runs `label` and its dependencies in order, streaming to the Output panel.
    func runWorkspaceTask(label: String) {
        guard let root = workspace?.rootURL, requireTrust(for: .task) else { return }
        guard taskCenter.runningLabel == nil else {
            statusMessage = "A task is already running: \(taskCenter.runningLabel ?? "")"
            return
        }
        let plan: [TaskDefinition]
        do {
            plan = try TaskService.executionPlan(for: label, in: taskCenter.tasks)
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        let context = TaskVariableContext(
            workspaceFolder: root.path,
            activeFile: focusedTab?.fileURL?.path,
            environment: ProcessInfo.processInfo.environment
        )
        showBottomPanel = true
        activeBottomPanel = .output
        taskCenter.runningLabel = label
        let center = taskCenter

        center.runTask = Task { [weak self] in
            var failed = false
            for task in plan {
                guard let self else { break }
                self.scriptOutput += "\n> Executing task: \(task.label)\n"
                let startOffset = self.scriptOutput.utf8.count
                // An AsyncStream keeps chunks in order (one Task per chunk would not).
                let (chunks, sink) = AsyncStream<String>.makeStream()
                let consumer = Task { @MainActor [weak self] in
                    for await chunk in chunks { self?.scriptOutput += chunk }
                }
                let status: Int32
                do {
                    status = try await center.service.run(task, context: context) { sink.yield($0) }
                } catch {
                    sink.finish()
                    await consumer.value
                    self.scriptOutput += "Error: \(error.localizedDescription)\n"
                    failed = true
                    break
                }
                sink.finish()
                await consumer.value
                if !task.problemMatchers.isEmpty {
                    let tail = String(decoding: Array(self.scriptOutput.utf8.dropFirst(startOffset)), as: UTF8.self)
                    let count = TaskService.problems(in: tail, matchers: task.problemMatchers,
                                                     directory: root).count
                    self.scriptOutput += "[tasks] \(count) problem\(count == 1 ? "" : "s") matched\n"
                }
                self.scriptOutput += "[Task \"\(task.label)\" exited with code \(status)]\n"
                if status != 0 || Task.isCancelled { failed = true; break }
            }
            center.runningLabel = nil
            self?.statusMessage = failed ? "Task failed: \(label)" : "Task finished: \(label)"
        }
    }

    func stopWorkspaceTask() {
        taskCenter.runTask?.cancel()
        Task { await taskCenter.service.stopAll() }
    }
}
