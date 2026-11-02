// BreakpointRequestBuilder.swift
// Athena — pure translation of breakpoint options into DAP / CDP requests,
// logpoint interpolation and hit-count matching. No I/O, so it is unit-tested.
// Swift 6, strict concurrency.

import Foundation

// MARK: - Hit condition

/// A parsed hit-count condition (`5`, `==5`, `>5`, `>=5`, `<5`, `<=5`, `%5`).
/// A bare number means "equals". The DAP backend receives the user's raw
/// string (adapters interpret it themselves); CDP and SFCC use this.
struct HitCondition: Sendable, Equatable {
    enum Op: String, Sendable { case eq = "==", gt = ">", ge = ">=", lt = "<", le = "<=", mod = "%" }
    let op: Op
    let value: Int

    static func parse(_ raw: String?) -> HitCondition? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var op = Op.eq
        for candidate in [Op.ge, .le, .eq, .gt, .lt, .mod] where s.hasPrefix(candidate.rawValue) {
            op = candidate
            s = String(s.dropFirst(candidate.rawValue.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if op == .eq, s.hasPrefix("=") { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) } // "===" tolerance
        guard let n = Int(s), n >= 0, !(op == .mod && n == 0) else { return nil }
        return HitCondition(op: op, value: n)
    }

    func matches(hitCount n: Int) -> Bool {
        switch op {
        case .eq:  return n == value
        case .gt:  return n > value
        case .ge:  return n >= value
        case .lt:  return n < value
        case .le:  return n <= value
        case .mod: return n % value == 0
        }
    }

    /// JavaScript predicate over a counter variable named `counter`.
    func javaScript(counter: String) -> String {
        switch op {
        case .mod: return "\(counter)%\(value)===0"
        default:   return "\(counter)\(op.rawValue == "==" ? "===" : op.rawValue)\(value)"
        }
    }
}

// MARK: - Log message template

enum LogMessageTemplate {
    enum Segment: Equatable, Sendable {
        case text(String)
        case expression(String)
    }

    /// Splits `"user {name} has {items.length} items"` into text and
    /// expression segments. `\{` and `\}` are literal braces; an empty `{}`
    /// or an unterminated `{` stays literal text.
    static func parse(_ message: String) -> [Segment] {
        var segments: [Segment] = []
        var text = ""
        let chars = Array(message)
        var i = 0
        func flushText() { if !text.isEmpty { segments.append(.text(text)); text = "" } }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "{" || chars[i + 1] == "}" {
                text.append(chars[i + 1]); i += 2; continue
            }
            if c == "{" {
                var depth = 1
                var j = i + 1
                while j < chars.count, depth > 0 {
                    if chars[j] == "{" { depth += 1 } else if chars[j] == "}" { depth -= 1 }
                    j += 1
                }
                if depth == 0 {
                    let expr = String(chars[(i + 1)..<(j - 1)]).trimmingCharacters(in: .whitespaces)
                    if !expr.isEmpty {
                        flushText()
                        segments.append(.expression(expr))
                        i = j
                        continue
                    }
                }
            }
            text.append(c)
            i += 1
        }
        flushText()
        return segments
    }

    /// Renders with a synchronous evaluator (used by tests and callers that
    /// already hold values).
    static func render(_ message: String, evaluate: (String) -> String) -> String {
        parse(message).map {
            switch $0 {
            case .text(let t): return t
            case .expression(let e): return evaluate(e)
            }
        }.joined()
    }

    /// A JavaScript template literal (backticks included) that interpolates
    /// each expression, guarding against throwing expressions.
    static func javaScriptTemplate(_ message: String) -> String {
        var out = "`"
        for segment in parse(message) {
            switch segment {
            case .text(let t):
                out += t.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "$", with: "\\$")
                    .replacingOccurrences(of: "\n", with: "\\n")
            case .expression(let e):
                out += "${(()=>{try{return (\(e))}catch(_e){return '<'+_e+'>'}})()}"
            }
        }
        return out + "`"
    }
}

// MARK: - Request builders

enum BreakpointRequestBuilder {

    /// Lines worth sending to a backend: enabled ones only, sorted.
    static func activeLines(_ lines: Set<Int>, options: [Int: BreakpointOptions]) -> [Int] {
        lines.filter { options[$0]?.isEnabled ?? true }.sorted()
    }

    /// DAP `SourceBreakpoint` array for `setBreakpoints`.
    static func dapSourceBreakpoints(lines: [Int], options: [Int: BreakpointOptions]) -> [[String: Any]] {
        lines.sorted().map { line in
            var bp: [String: Any] = ["line": line]
            guard let o = options[line] else { return bp }
            if !BreakpointOptions.blank(o.condition) { bp["condition"] = o.condition!.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !BreakpointOptions.blank(o.hitCondition) { bp["hitCondition"] = o.hitCondition!.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !BreakpointOptions.blank(o.logMessage) { bp["logMessage"] = o.logMessage! }
            return bp
        }
    }

    /// Full `setBreakpoints` arguments for one file.
    static func dapSetBreakpointsArgs(path: String, lines: [Int], options: [Int: BreakpointOptions]) -> [String: Any] {
        [
            "source": ["path": path, "name": (path as NSString).lastPathComponent],
            "breakpoints": dapSourceBreakpoints(lines: lines, options: options),
            "sourceModified": false,
        ]
    }

    /// Filter ids to send to `setExceptionBreakpoints`. `available` is the
    /// adapter's advertised `exceptionBreakpointFilters` ids; adapters name
    /// them differently ("all"/"raised"/"cpp_throw", "uncaught"/"unhandled").
    static func dapExceptionFilters(_ s: ExceptionBreakpointSettings, available: [String]) -> [String] {
        let allNames = ["all", "raised", "cpp_throw", "swift_throw", "objc_throw"]
        let uncaughtNames = ["uncaught", "unhandled", "userUnhandled"]
        func pick(_ names: [String]) -> [String] {
            let hits = names.filter { available.contains($0) }
            return available.isEmpty ? [names[0]] : hits
        }
        if s.breakOnAll { return pick(allNames) }
        if s.breakOnUncaught { return pick(uncaughtNames) }
        return []
    }

    /// CDP `Debugger.setPauseOnExceptions` state.
    static func cdpPauseOnExceptionsState(_ s: ExceptionBreakpointSettings) -> String {
        s.breakOnAll ? "all" : (s.breakOnUncaught ? "uncaught" : "none")
    }

    /// The CDP breakpoint `condition` implementing condition + hit count +
    /// logpoint together, or nil for a plain breakpoint. Order mirrors
    /// VS Code: condition first, then hit count (counted only when the
    /// condition held), then the logpoint (which never stops).
    static func cdpCondition(options: BreakpointOptions?, key: String) -> String? {
        guard let o = options else { return nil }
        let cond = BreakpointOptions.blank(o.condition) ? nil : o.condition!.trimmingCharacters(in: .whitespacesAndNewlines)
        let hit = HitCondition.parse(o.hitCondition)
        let log = BreakpointOptions.blank(o.logMessage) ? nil : o.logMessage
        if cond == nil, hit == nil, log == nil { return nil }
        // Only a condition: hand V8 the bare expression.
        if let cond, hit == nil, log == nil { return cond }

        var body = "(()=>{"
        if let cond { body += "if(!(\(cond)))return false;" }
        if let hit {
            body += "var _h=(globalThis.__athenaHits=globalThis.__athenaHits||{});"
            body += "var _n=_h[\(jsString(key))]=(_h[\(jsString(key))]||0)+1;"
            body += "if(!(\(hit.javaScript(counter: "_n"))))return false;"
        }
        if let log {
            body += "console.log(\(LogMessageTemplate.javaScriptTemplate(log)));return false;"
        } else {
            body += "return true;"
        }
        return body + "})()"
    }

    /// Whether an evaluated condition string counts as true (SFCC evaluates
    /// conditions client-side and gets strings back).
    static func isTruthy(_ evaluated: String) -> Bool {
        let s = evaluated.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["", "false", "0", "undefined", "null", "nan", "\"\"", "''"].contains(s)
    }

    private static func jsString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: Persistence

    static func persisted(lines: [String: Set<Int>], options: [String: [Int: BreakpointOptions]],
                          exceptions: ExceptionBreakpointSettings) -> PersistedDebugConfiguration {
        var list: [PersistedBreakpoint] = []
        for file in lines.keys.sorted() {
            for line in lines[file, default: []].sorted() {
                list.append(PersistedBreakpoint(filePath: file, line: line, options: options[file]?[line] ?? BreakpointOptions()))
            }
        }
        return PersistedDebugConfiguration(breakpoints: list, exceptions: exceptions)
    }

    static func restore(_ config: PersistedDebugConfiguration)
        -> (lines: [String: Set<Int>], options: [String: [Int: BreakpointOptions]]) {
        var lines: [String: Set<Int>] = [:]
        var options: [String: [Int: BreakpointOptions]] = [:]
        for bp in config.breakpoints {
            lines[bp.filePath, default: []].insert(bp.line)
            if bp.options != BreakpointOptions() { options[bp.filePath, default: [:]][bp.line] = bp.options }
        }
        return (lines, options)
    }
}

// MARK: - Inline values

/// Builds the end-of-line "x = 1, name = "a"" annotation for the stopped line.
enum InlineValueFormatter {
    static func annotation(forLine line: String, variables: [DebugVariable],
                           maxItems: Int = 5, maxValueLength: Int = 40) -> String? {
        guard !variables.isEmpty else { return nil }
        let byName = Dictionary(variables.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var parts: [String] = []
        let chars = Array(line)
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
        var i = 0
        while i < chars.count {
            guard isIdent(chars[i]) else { i += 1; continue }
            var j = i
            while j < chars.count, isIdent(chars[j]) { j += 1 }
            let token = String(chars[i..<j])
            // `obj.name` is a member access, not the local `name`.
            let isMember = i > 0 && chars[i - 1] == "."
            if !isMember, let v = byName[token], seen.insert(token).inserted {
                var value = v.value.replacingOccurrences(of: "\n", with: " ")
                if value.count > maxValueLength { value = String(value.prefix(maxValueLength)) + "…" }
                parts.append("\(token) = \(value)")
            }
            i = j
        }
        guard !parts.isEmpty else { return nil }
        return parts.prefix(maxItems).joined(separator: ", ")
    }
}
