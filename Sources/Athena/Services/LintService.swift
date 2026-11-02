// LintService.swift
// Athena — runs the workspace's own ESLint / Biome / tsc and `npm audit`; parses their output.
// Swift 6, strict concurrency.

import Foundation

enum LintError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let m): return m }
    }
}

// MARK: - LintService

actor LintService {

    // MARK: - Availability

    /// The project-local binary, as `PrettierService` resolves Prettier —
    /// never a global install. tsc additionally needs a tsconfig.json.
    nonisolated func binary(for tool: LintTool, root: URL) -> URL? {
        let url = root.appendingPathComponent("node_modules/.bin/\(tool.rawValue)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        if tool == .tsc,
           !FileManager.default.fileExists(atPath: root.appendingPathComponent("tsconfig.json").path) { return nil }
        return url
    }

    // MARK: - Linting

    /// Diagnostics for `file` (ESLint, Biome) or the whole project (tsc,
    /// where `file` is ignored). `nil` when the tool isn't installed.
    func lint(tool: LintTool, file: URL?, root: URL, reportUnused: Bool = false) async throws -> [Diagnostic]? {
        guard let exe = binary(for: tool, root: root) else { return nil }
        switch tool {
        case .eslint:
            guard let file else { return nil }
            let r = try await ProcessCapture.run(executable: exe, arguments: ["-f", "json", file.path], cwd: root)
            guard r.status <= 1 else { throw LintError.failed("eslint: " + firstLine(r.stderr)) }
            return LintOutputParser.parseESLintJSON(Data(r.stdout.utf8))
        case .biome:
            guard let file else { return nil }
            let r = try await ProcessCapture.run(executable: exe,
                                                 arguments: ["check", "--reporter=github", file.path], cwd: root)
            return LintOutputParser.parseBiomeGitHub(r.stdout, directory: root)
        case .tsc:
            var args = ["--noEmit", "--pretty", "false"]
            if reportUnused { args.append("--noUnusedLocals") }
            let r = try await ProcessCapture.run(executable: exe, arguments: args, cwd: root)
            return LintOutputParser.parseTSC(r.stdout, directory: root)
        }
    }

    /// `eslint --fix` / `biome check --write` on one file. Returns false if
    /// the tool is missing or failed to run.
    func fix(tool: LintTool, file: URL, root: URL) async -> Bool {
        guard let exe = binary(for: tool, root: root) else { return false }
        let args: [String]
        switch tool {
        case .eslint: args = ["--fix", file.path]
        case .biome: args = ["check", "--write", file.path]
        case .tsc: return false
        }
        return (try? await ProcessCapture.run(executable: exe, arguments: args, cwd: root)) != nil
    }

    // MARK: - npm audit

    func audit(root: URL) async throws -> AuditReport {
        let r = try await ProcessCapture.runLoginShell("npm audit --json", cwd: root)
        // npm exits non-zero when vulnerabilities exist; the JSON is still on stdout.
        guard let report = NPMAuditParser.parse(Data(r.stdout.utf8)) else {
            throw LintError.failed("npm audit: " + firstLine(r.stderr.isEmpty ? r.stdout : r.stderr))
        }
        return report
    }

    private func firstLine(_ s: String) -> String {
        s.split(separator: "\n").first.map(String.init) ?? "no output"
    }
}

// MARK: - LintOutputParser

enum LintOutputParser {

    /// `eslint -f json`: `[{ filePath, messages: [{ ruleId, severity, message, line, column }] }]`.
    static func parseESLintJSON(_ data: Data) -> [Diagnostic] {
        guard let files = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [Diagnostic] = []
        for file in files {
            guard let path = file["filePath"] as? String else { continue }
            for m in file["messages"] as? [[String: Any]] ?? [] {
                guard var message = m["message"] as? String else { continue }
                if message.hasPrefix("File ignored") { continue }
                if let rule = m["ruleId"] as? String { message += " (\(rule))" }
                out.append(Diagnostic(
                    fileURL: URL(fileURLWithPath: path),
                    line: max(1, m["line"] as? Int ?? 1), column: max(1, m["column"] as? Int ?? 1),
                    message: message,
                    severity: (m["severity"] as? Int) == 2 ? .error : .warning,
                    source: "eslint"))
            }
        }
        return out
    }

    /// Biome's `--reporter=github`: `::error title=lint/x,file=a.ts,line=1,endLine=1,col=7,endColumn=8::message`.
    static func parseBiomeGitHub(_ output: String, directory: URL) -> [Diagnostic] {
        guard let line = try? NSRegularExpression(pattern: #"^::(error|warning|notice) (.*?)::(.*)$"#),
              let prop = try? NSRegularExpression(pattern: #"(\w+)=([^,]*)"#) else { return [] }
        var out: [Diagnostic] = []
        for raw in output.split(separator: "\n") {
            let text = String(raw)
            guard let m = line.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let level = Range(m.range(at: 1), in: text), let props = Range(m.range(at: 2), in: text),
                  let msg = Range(m.range(at: 3), in: text) else { continue }
            var dict: [String: String] = [:]
            let p = String(text[props])
            for pm in prop.matches(in: p, range: NSRange(p.startIndex..., in: p)) {
                if let k = Range(pm.range(at: 1), in: p), let v = Range(pm.range(at: 2), in: p) {
                    dict[String(p[k])] = String(p[v])
                }
            }
            guard let file = dict["file"] else { continue }
            let url = file.hasPrefix("/") ? URL(fileURLWithPath: file)
                                          : directory.appendingPathComponent(file).standardizedFileURL
            var message = String(text[msg])
            if let title = dict["title"] { message += " (\(title))" }
            out.append(Diagnostic(
                fileURL: url, line: Int(dict["line"] ?? "") ?? 1, column: Int(dict["col"] ?? "") ?? 1,
                message: message,
                severity: text[level] == "error" ? .error : (text[level] == "warning" ? .warning : .information),
                source: "biome"))
        }
        return out
    }

    /// `tsc --pretty false`: `src/a.ts(12,5): error TS2322: message`.
    static func parseTSC(_ output: String, directory: URL) -> [Diagnostic] {
        guard let re = try? NSRegularExpression(
            pattern: #"^(.+?)\((\d+),(\d+)\):\s+(error|warning)\s+(TS\d+):\s+(.*)$"#,
            options: .anchorsMatchLines) else { return [] }
        return re.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap { m in
            func g(_ i: Int) -> String { Range(m.range(at: i), in: output).map { String(output[$0]) } ?? "" }
            guard let line = Int(g(2)), let col = Int(g(3)) else { return nil }
            let path = g(1)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                          : directory.appendingPathComponent(path).standardizedFileURL
            return Diagnostic(fileURL: url, line: line, column: col, message: "\(g(6)) (\(g(5)))",
                              severity: g(4) == "warning" ? .warning : .error, source: "tsc")
        }
    }
}

// MARK: - NPMAuditParser

enum NPMAuditParser {

    private static let severityOrder = ["critical", "high", "moderate", "low", "info"]

    /// `npm audit --json`, npm 7+ (`vulnerabilities`) or npm 6 (`advisories`). `nil` if not an audit report.
    static func parse(_ data: Data) -> AuditReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var vulns: [AuditVulnerability] = []

        if let map = root["vulnerabilities"] as? [String: [String: Any]] {
            for (name, v) in map {
                var title = ""
                var url: String?
                for via in v["via"] as? [Any] ?? [] {
                    if let d = via as? [String: Any] {
                        title = (d["title"] as? String) ?? title
                        url = (d["url"] as? String) ?? url
                    } else if let s = via as? String, title.isEmpty {
                        title = "via \(s)"
                    }
                }
                let fix = v["fixAvailable"]
                vulns.append(AuditVulnerability(
                    name: (v["name"] as? String) ?? name, severity: (v["severity"] as? String) ?? "info",
                    title: title, url: url, range: v["range"] as? String,
                    isDirect: (v["isDirect"] as? Bool) ?? false,
                    fixAvailable: (fix as? Bool) ?? (fix is [String: Any])))
            }
        } else if let map = root["advisories"] as? [String: [String: Any]] {
            for (_, a) in map {
                vulns.append(AuditVulnerability(
                    name: (a["module_name"] as? String) ?? "?", severity: (a["severity"] as? String) ?? "info",
                    title: (a["title"] as? String) ?? "", url: a["url"] as? String,
                    range: a["vulnerable_versions"] as? String, isDirect: true, fixAvailable: false))
            }
        } else if root["metadata"] == nil {
            return nil
        }

        vulns.sort {
            let a = severityOrder.firstIndex(of: $0.severity) ?? 99, b = severityOrder.firstIndex(of: $1.severity) ?? 99
            return (a, $0.name) < (b, $1.name)
        }
        var counts: [String: Int] = [:]
        if let meta = (root["metadata"] as? [String: Any])?["vulnerabilities"] as? [String: Any] {
            for s in severityOrder { if let n = meta[s] as? Int, n > 0 { counts[s] = n } }
        } else {
            for v in vulns { counts[v.severity, default: 0] += 1 }
        }
        return AuditReport(vulnerabilities: vulns, counts: counts)
    }

    static func render(_ report: AuditReport) -> String {
        if report.vulnerabilities.isEmpty { return "[npm audit] No vulnerabilities found.\n" }
        var out = "[npm audit] " + severityOrder.compactMap { s in
            report.counts[s].map { "\($0) \(s)" }
        }.joined(separator: ", ") + "\n"
        for v in report.vulnerabilities {
            out += "  [\(v.severity)] \(v.name)\(v.isDirect ? "" : " (transitive)")"
            if let r = v.range { out += " \(r)" }
            out += "\n    \(v.title)"
            if let u = v.url { out += "  \(u)" }
            out += v.fixAvailable ? "  (fix available: npm audit fix)\n" : "\n"
        }
        return out
    }
}
