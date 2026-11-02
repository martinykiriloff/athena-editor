// AppState+Diagnostics.swift
// Athena — external diagnostic feeds (ESLint, Biome, tsc, task problem matchers), run-on-save, npm audit.
// Swift 6, strict concurrency.

import Foundation

// MARK: - DiagnosticsCenter

/// State for diagnostics that don't come from an LSP server. Each feed (keyed
/// "eslint", "biome", "tsc", "task:<label>") owns its own dictionary, so an
/// LSP `publishDiagnostics` (which replaces `AppState.diagnostics[url]`) can
/// never overwrite them; `AppState.allDiagnostics(for:)` merges at read time.
@Observable @MainActor
final class DiagnosticsCenter {
    var feeds: [String: [URL: [Diagnostic]]] = [:]
    var eslintOnSave = true
    var biomeOnSave = true
    var tscOnSave = false
    var fixOnSave = false
    var tscReportUnused = false
    var isRunning = false
    @ObservationIgnored let service = LintService()
    @ObservationIgnored var debounce: Task<Void, Never>?
    @ObservationIgnored var pending: Set<URL> = []

    func clearAll() {
        feeds = [:]
        pending = []
        debounce?.cancel()
    }
}

// MARK: - AppState

@MainActor
extension AppState {

    static let lintableExtensions: Set<String> = ["js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts"]

    // MARK: - Merging

    /// LSP diagnostics for `url` plus every external feed's.
    func allDiagnostics(for url: URL) -> [Diagnostic] {
        var list = diagnostics[url] ?? []
        for feed in diagnosticsCenter.feeds.values { list += feed[url] ?? [] }
        return list
    }

    /// Every file's diagnostics, LSP and external feeds merged.
    var mergedDiagnostics: [URL: [Diagnostic]] {
        var merged = diagnostics
        for feed in diagnosticsCenter.feeds.values {
            for (url, list) in feed where !list.isEmpty { merged[url, default: []] += list }
        }
        return merged
    }

    // MARK: - Settings

    func loadDiagnosticsSettings() async {
        let c = diagnosticsCenter
        c.eslintOnSave = await settingsService.value(for: "lintEslintOnSave", default: true)
        c.biomeOnSave = await settingsService.value(for: "lintBiomeOnSave", default: true)
        c.tscOnSave = await settingsService.value(for: "lintTscOnSave", default: false)
        c.fixOnSave = await settingsService.value(for: "lintFixOnSave", default: false)
        c.tscReportUnused = await settingsService.value(for: "lintTscUnused", default: false)
    }

    // MARK: - Task problems

    /// Replaces the problems a task reported (an empty list clears them).
    func setTaskDiagnostics(label: String, _ list: [Diagnostic]) {
        var byFile: [URL: [Diagnostic]] = [:]
        for var d in list {
            d.source = "task: \(label)"
            byFile[d.fileURL, default: []].append(d)
        }
        diagnosticsCenter.feeds["task:\(label)"] = byFile
    }

    // MARK: - Run on save

    /// Called after a save. Debounced (the burst of auto-saves while typing
    /// would otherwise spawn a linter per keystroke pause).
    func scheduleDiagnostics(forSaved url: URL) {
        guard Self.lintableExtensions.contains(url.pathExtension.lowercased()),
              let root = workspace?.rootURL else { return }
        let c = diagnosticsCenter
        guard c.eslintOnSave || c.biomeOnSave || c.tscOnSave else { return }
        c.pending.insert(url)
        c.debounce?.cancel()
        c.debounce = Task { [weak self] in
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(700)))
            guard !Task.isCancelled, let self else { return }
            let files = Array(c.pending)
            c.pending = []
            await self.runLinters(files: files, root: root, tsc: c.tscOnSave)
        }
    }

    /// "Run Diagnostics": tsc for the project plus ESLint/Biome on the open files.
    func runWorkspaceDiagnostics() async {
        guard let root = workspace?.rootURL else { statusMessage = "Open a folder first."; return }
        let open = (tabs(in: .primary) + tabs(in: .secondary)).compactMap(\.fileURL)
            .filter { Self.lintableExtensions.contains($0.pathExtension.lowercased()) }
        statusMessage = "Running diagnostics…"
        await runLinters(files: open, root: root, tsc: true, force: true)
        statusMessage = "Diagnostics finished"
    }

    private func runLinters(files: [URL], root: URL, tsc: Bool, force: Bool = false) async {
        let c = diagnosticsCenter
        let service = c.service
        c.isRunning = true
        defer { c.isRunning = false }

        var tools: [LintTool] = []
        if c.eslintOnSave || force { tools.append(.eslint) }
        if c.biomeOnSave || force { tools.append(.biome) }

        for file in files {
            for tool in tools {
                if c.fixOnSave && !force {
                    // The tab reloads from disk through the file watcher when it is clean.
                    _ = await service.fix(tool: tool, file: file, root: root)
                }
                do {
                    if let found = try await service.lint(tool: tool, file: file, root: root) {
                        var feed = c.feeds[tool.rawValue] ?? [:]
                        feed[file] = found.filter { $0.fileURL.standardizedFileURL == file.standardizedFileURL }
                        c.feeds[tool.rawValue] = feed
                    }
                } catch {
                    scriptOutput += "[\(tool.rawValue)] \(error.localizedDescription)\n"
                }
            }
        }

        if tsc {
            do {
                if let found = try await service.lint(tool: .tsc, file: nil, root: root,
                                                      reportUnused: c.tscReportUnused) {
                    var byFile: [URL: [Diagnostic]] = [:]
                    for d in found { byFile[d.fileURL, default: []].append(d) }
                    c.feeds["tsc"] = byFile
                }
            } catch {
                scriptOutput += "[tsc] \(error.localizedDescription)\n"
            }
        }
    }

    // MARK: - npm audit

    /// Runs `npm audit --json` and prints the vulnerabilities in the Output panel.
    func runNPMAudit() async {
        guard let root = workspace?.rootURL else { statusMessage = "Open a folder first."; return }
        showBottomPanel = true
        activeBottomPanel = .output
        statusMessage = "Running npm audit…"
        scriptOutput += "\n> npm audit\n"
        do {
            let report = try await diagnosticsCenter.service.audit(root: root)
            scriptOutput += NPMAuditParser.render(report)
            statusMessage = report.vulnerabilities.isEmpty ? "npm audit: clean" : "npm audit: \(report.vulnerabilities.count) vulnerable packages"
        } catch {
            scriptOutput += "\(error.localizedDescription)\n"
            statusMessage = "npm audit failed"
        }
    }
}
