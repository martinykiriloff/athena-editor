// AppState+Breakpoints.swift
// Athena — conditional / hit-count / logpoint breakpoints, exception pauses, inline values, per-workspace persistence.
// Swift 6, strict concurrency.

import AppKit
import Foundation

// MARK: - BreakpointCenter

/// State for breakpoint extras. A separate object (held by `AppState` as
/// `breakpointCenter`) because an extension can't add stored properties.
@Observable @MainActor
final class BreakpointCenter {
    /// Per-file, per-line options. A line absent here is a plain breakpoint.
    var options: [String: [Int: BreakpointOptions]] = [:]
    var exceptions = ExceptionBreakpointSettings()
    /// 1-based line → "x = 1, y = 2" for the line the debugger is stopped on.
    var inlineValues: [Int: String] = [:]
    @ObservationIgnored var workspaceRoot: URL?
}

// MARK: - BreakpointStore

/// Reads and writes one workspace's breakpoints under
/// `~/Library/Application Support/Athena/breakpoints/`.
enum BreakpointStore {
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Athena/breakpoints", isDirectory: true)
    }

    /// Stable per-workspace file name: folder name plus a djb2 hash of the full path.
    static func fileURL(forWorkspace root: URL, in directory: URL = defaultDirectory()) -> URL {
        var hash: UInt64 = 5381
        for b in root.standardizedFileURL.path.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return directory.appendingPathComponent("\(root.lastPathComponent)-\(String(hash, radix: 16)).json")
    }

    static func load(workspace root: URL, directory: URL = defaultDirectory()) -> PersistedDebugConfiguration? {
        guard let data = try? Data(contentsOf: fileURL(forWorkspace: root, in: directory)) else { return nil }
        return try? JSONDecoder().decode(PersistedDebugConfiguration.self, from: data)
    }

    static func save(_ config: PersistedDebugConfiguration, workspace root: URL, directory: URL = defaultDirectory()) {
        let url = fileURL(forWorkspace: root, in: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Edit kinds

enum BreakpointEditKind: Sendable {
    case condition, hitCount, logMessage, toggleEnabled, remove
}

// MARK: - AppState

@MainActor
extension AppState {

    /// Enabled breakpoint lines of a file, sorted — what backends receive.
    func activeBreakpointLines(in file: String) -> [Int] {
        BreakpointRequestBuilder.activeLines(debugBreakpoints[file] ?? [], options: breakpointCenter.options[file] ?? [:])
    }

    /// Gutter glyph styles for one file.
    func breakpointStyles(for file: String) -> [Int: BreakpointGlyphStyle] {
        var styles: [Int: BreakpointGlyphStyle] = [:]
        for (line, o) in breakpointCenter.options[file] ?? [:] { styles[line] = o.glyphStyle }
        return styles
    }

    /// Called after any breakpoint-set change: pushes to a live session and persists.
    func breakpointsDidChange(changedFile: String?) {
        if let changedFile { pushBreakpointsToLiveSession(changedFile: changedFile) }
        persistBreakpoints()
    }

    func persistBreakpoints() {
        guard let root = workspace?.rootURL else { return }
        let config = BreakpointRequestBuilder.persisted(lines: debugBreakpoints, options: breakpointCenter.options,
                                                        exceptions: breakpointCenter.exceptions)
        BreakpointStore.save(config, workspace: root)
    }

    /// Restores this workspace's saved breakpoints (called when a folder opens).
    func loadPersistedBreakpoints(for root: URL) {
        breakpointCenter.workspaceRoot = root
        guard let config = BreakpointStore.load(workspace: root) else {
            debugBreakpoints = [:]
            breakpointCenter.options = [:]
            breakpointCenter.exceptions = ExceptionBreakpointSettings()
            return
        }
        let restored = BreakpointRequestBuilder.restore(config)
        debugBreakpoints = restored.lines
        breakpointCenter.options = restored.options
        breakpointCenter.exceptions = config.exceptions
    }

    // MARK: Editing

    func editBreakpoint(filePath: String, line: Int, kind: BreakpointEditKind) {
        var o = breakpointCenter.options[filePath]?[line] ?? BreakpointOptions()
        switch kind {
        case .remove:
            if debugBreakpoints[filePath]?.contains(line) == true { toggleBreakpoint(filePath: filePath, line: line) }
            return
        case .toggleEnabled:
            o.isEnabled.toggle()
        case .condition:
            guard let text = BreakpointPrompt.ask(title: "Breakpoint Condition",
                                                  message: "Stop only when this expression is truthy.",
                                                  initial: o.condition ?? "") else { return }
            o.condition = text.isEmpty ? nil : text
            o.logMessage = nil
        case .hitCount:
            guard let text = BreakpointPrompt.ask(title: "Hit Count",
                                                  message: "Stop on a matching hit: 5, ==5, >=5, >5, <5, <=5 or %5.",
                                                  initial: o.hitCondition ?? "") else { return }
            if !text.isEmpty, HitCondition.parse(text) == nil {
                statusMessage = "Not a valid hit count: \(text)"
                return
            }
            o.hitCondition = text.isEmpty ? nil : text
        case .logMessage:
            guard let text = BreakpointPrompt.ask(title: "Logpoint",
                                                  message: "Message to log instead of stopping. Use {expression} to interpolate.",
                                                  initial: o.logMessage ?? "") else { return }
            o.logMessage = text.isEmpty ? nil : text
        }
        if debugBreakpoints[filePath] == nil { debugBreakpoints[filePath] = [] }
        debugBreakpoints[filePath]?.insert(line)
        breakpointCenter.options[filePath, default: [:]][line] = o.isPlain && o == BreakpointOptions() ? nil : o
        breakpointsDidChange(changedFile: filePath)
    }

    func setExceptionBreakpoints(all: Bool? = nil, uncaught: Bool? = nil) {
        var s = breakpointCenter.exceptions
        if let all { s.breakOnAll = all }
        if let uncaught { s.breakOnUncaught = uncaught }
        breakpointCenter.exceptions = s
        persistBreakpoints()
        switch debugState {
        case .running, .paused:
            Task { try? await debugService.updateExceptionBreakpoints(s) }
        default: break
        }
    }

    // MARK: Inline values

    /// Recomputes the stopped line's "name = value" annotation from the
    /// freshly fetched top-frame variables and the line's current text.
    func updateInlineDebugValues() {
        breakpointCenter.inlineValues = [:]
        guard let file = debugCurrentFile, let line = debugCurrentLine, line > 0 else { return }
        let text: String
        if let tab = openTabs.first(where: { $0.fileURL?.path == file.path }) {
            text = tab.content
        } else if let disk = try? String(contentsOf: file, encoding: .utf8) {
            text = disk
        } else { return }
        let lines = text.components(separatedBy: "\n")
        guard line <= lines.count,
              let annotation = InlineValueFormatter.annotation(forLine: lines[line - 1], variables: debugVariables)
        else { return }
        breakpointCenter.inlineValues = [line: annotation]
    }
}

// MARK: - BreakpointPrompt

/// A one-field modal prompt (AppKit alert with a text field accessory).
@MainActor
enum BreakpointPrompt {
    static func ask(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
