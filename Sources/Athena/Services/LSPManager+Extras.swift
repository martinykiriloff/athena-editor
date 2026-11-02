// LSPManager+Extras.swift
// Athena — inlay hints, semantic tokens, code lens, call/type hierarchy, linked editing,
// file-operation notifications and source code actions. Parsing is static and unit-tested.
// Swift 6, strict concurrency.

import Foundation

extension LSPManager {

    // MARK: - Client capability vocabulary

    /// Token types/modifiers the client advertises; the server's legend is
    /// what actually indexes `data`, these only declare what we understand.
    static let semanticTokenTypes: [String] = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
        "parameter", "variable", "property", "enumMember", "event", "function", "method",
        "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator",
    ]
    static let semanticTokenModifiers: [String] = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract",
        "async", "modification", "documentation", "defaultLibrary",
    ]

    /// Most lenses resolved per document refresh.
    static let maxLensResolves = 40

    // MARK: - Capabilities

    /// Reads the Wave 2 provider flags from an `initialize` reply. A provider
    /// is on when it is `true` or an options object. Anything unparseable
    /// yields "nothing supported" so the features stay quietly off.
    static func extraCapabilities(fromInitializeReply data: Data) -> LSPExtraCapabilities {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let caps = result["capabilities"] as? [String: Any] else { return LSPExtraCapabilities() }

        func enabled(_ key: String) -> Bool {
            guard let v = caps[key] else { return false }
            if let b = v as? Bool { return b }
            return v is [String: Any]
        }

        var out = LSPExtraCapabilities()
        out.inlayHints = enabled("inlayHintProvider")
        out.callHierarchy = enabled("callHierarchyProvider")
        out.typeHierarchy = enabled("typeHierarchyProvider")
        out.linkedEditing = enabled("linkedEditingRangeProvider")
        out.codeActions = enabled("codeActionProvider")

        if let lens = caps["codeLensProvider"] {
            out.codeLens = (lens as? Bool) ?? (lens is [String: Any])
            out.codeLensResolve = (lens as? [String: Any])?["resolveProvider"] as? Bool ?? false
        }

        if let sem = caps["semanticTokensProvider"] as? [String: Any],
           let legend = sem["legend"] as? [String: Any],
           let types = legend["tokenTypes"] as? [String] {
            let full = sem["full"]
            out.semanticTokensFull = (full as? Bool) ?? (full is [String: Any])
            out.semanticLegend = SemanticTokensLegend(
                tokenTypes: types, tokenModifiers: legend["tokenModifiers"] as? [String] ?? []
            )
        }

        if let ws = caps["workspace"] as? [String: Any],
           let ops = ws["fileOperations"] as? [String: Any] {
            out.willRenameFilters = parseFileOperationFilters(ops["willRename"])
            out.didRenameFilters = parseFileOperationFilters(ops["didRename"])
        }
        return out
    }

    private static func parseFileOperationFilters(_ value: Any?) -> [FileOperationFilter] {
        guard let reg = value as? [String: Any], let filters = reg["filters"] as? [[String: Any]] else { return [] }
        return filters.compactMap { filter in
            guard let pattern = filter["pattern"] as? [String: Any], let glob = pattern["glob"] as? String else { return nil }
            let ignoreCase = (pattern["options"] as? [String: Any])?["ignoreCase"] as? Bool ?? false
            return FileOperationFilter(glob: glob, matches: pattern["matches"] as? String, ignoreCase: ignoreCase)
        }
    }

    /// Whether any filter accepts `path`. No filters means the server did not
    /// ask for this notification.
    static func fileOperationMatches(_ filters: [FileOperationFilter], path: String, isDirectory: Bool) -> Bool {
        filters.contains { filter in
            if let kind = filter.matches, (kind == "folder") != isDirectory { return false }
            guard let regex = globRegex(filter.glob, ignoreCase: filter.ignoreCase) else { return false }
            return regex.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
        }
    }

    /// Translates an LSP glob (`**`, `*`, `?`, `{a,b}`, `[abc]`) into an
    /// anchored regular expression.
    static func globRegex(_ glob: String, ignoreCase: Bool = false) -> NSRegularExpression? {
        var out = "^"
        let chars = Array(glob)
        var i = 0
        var braceDepth = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    // `**/` also matches zero directories.
                    if i + 2 < chars.count, chars[i + 2] == "/" { out += "(?:.*/)?"; i += 2 } else { out += ".*"; i += 1 }
                } else {
                    out += "[^/]*"
                }
            case "?": out += "[^/]"
            case "{": out += "(?:"; braceDepth += 1
            case "}" where braceDepth > 0: out += ")"; braceDepth -= 1
            case "," where braceDepth > 0: out += "|"
            case "[", "]": out.append(c)
            default:
                if "\\.+()|^$".contains(c) { out += "\\" }
                out.append(c)
            }
            i += 1
        }
        out += "$"
        return try? NSRegularExpression(pattern: out, options: ignoreCase ? [.caseInsensitive] : [])
    }

    // MARK: - Inlay hints

    /// `textDocument/inlayHint` for the whole document. Empty unless the
    /// server advertises `inlayHintProvider`.
    func inlayHints(fileURL: URL, lineCount: Int) async -> [InlayHint] {
        let language = Language.detect(from: fileURL)
        guard extraCapabilities[language]?.inlayHints == true else { return [] }
        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "range": [
                "start": ["line": 0, "character": 0],
                "end": ["line": max(lineCount, 1), "character": 0],
            ],
        ]
        guard let data = await rpc("textDocument/inlayHint", params, language: language) else { return [] }
        return Self.parseInlayHints(from: data)
    }

    /// Parses `InlayHint[] | null`. `label` is a string or `InlayHintLabelPart[]`.
    static func parseInlayHints(from data: Data) -> [InlayHint] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else { return [] }
        return result.compactMap { entry in
            guard let pos = entry["position"] as? [String: Any],
                  let line = pos["line"] as? Int, let character = pos["character"] as? Int else { return nil }
            let label: String
            if let s = entry["label"] as? String {
                label = s
            } else if let parts = entry["label"] as? [[String: Any]] {
                label = parts.compactMap { $0["value"] as? String }.joined()
            } else { return nil }
            guard !label.isEmpty else { return nil }
            return InlayHint(line: line, character: character, label: label, kind: entry["kind"] as? Int,
                             paddingLeft: entry["paddingLeft"] as? Bool ?? false,
                             paddingRight: entry["paddingRight"] as? Bool ?? false)
        }
    }

    // MARK: - Semantic tokens

    /// `textDocument/semanticTokens/full`, decoded with the server's legend.
    func semanticTokens(fileURL: URL) async -> [SemanticTokenSpan] {
        let language = Language.detect(from: fileURL)
        guard let caps = extraCapabilities[language], caps.semanticTokensFull, let legend = caps.semanticLegend else { return [] }
        let params: [String: Any] = ["textDocument": ["uri": fileURL.absoluteString]]
        guard let data = await rpc("textDocument/semanticTokens/full", params, language: language) else { return [] }
        return Self.decodeSemanticTokens(from: data, legend: legend)
    }

    /// Decodes the relative-encoded `SemanticTokens.data` (five integers per
    /// token: deltaLine, deltaStart, length, type index, modifier bitset).
    /// A trailing partial group and out-of-range type indices are dropped.
    static func decodeSemanticTokens(from data: Data, legend: SemanticTokensLegend) -> [SemanticTokenSpan] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let ints = result["data"] as? [Int] else { return [] }
        var spans: [SemanticTokenSpan] = []
        var line = 0, start = 0
        var i = 0
        while i + 4 < ints.count {
            let deltaLine = ints[i], deltaStart = ints[i + 1], length = ints[i + 2]
            let typeIndex = ints[i + 3], bits = ints[i + 4]
            i += 5
            if deltaLine == 0 { start += deltaStart } else { line += deltaLine; start = deltaStart }
            guard legend.tokenTypes.indices.contains(typeIndex), length > 0 else { continue }
            var mods: [String] = []
            for (index, name) in legend.tokenModifiers.enumerated() where index < 31 && bits & (1 << index) != 0 {
                mods.append(name)
            }
            spans.append(SemanticTokenSpan(line: line, startCharacter: start, length: length,
                                           tokenType: legend.tokenTypes[typeIndex], modifiers: mods))
        }
        return spans
    }

    // MARK: - Code lens

    /// `textDocument/codeLens`, then `codeLens/resolve` for lenses without a
    /// command when the server supports resolving. Resolves run concurrently.
    func codeLenses(fileURL: URL) async -> [CodeLens] {
        let language = Language.detect(from: fileURL)
        guard let caps = extraCapabilities[language], caps.codeLens else { return [] }
        let params: [String: Any] = ["textDocument": ["uri": fileURL.absoluteString]]
        guard let data = await rpc("textDocument/codeLens", params, language: language) else { return [] }
        var lenses = Self.parseCodeLenses(from: data)
        guard caps.codeLensResolve else { return lenses.filter { $0.command != nil } }

        // Resolve concurrently, capped so a huge file cannot flood the server.
        let pending = Array(lenses.enumerated().filter { $0.element.command == nil }.prefix(Self.maxLensResolves))
            .map { (index: $0.offset, lens: $0.element) }
        let resolved: [(Int, CodeLens)] = await withTaskGroup(of: (Int, CodeLens)?.self) { group in
            for item in pending {
                group.addTask { [self] in
                    guard let params = try? JSONSerialization.jsonObject(with: item.lens.raw) as? [String: Any],
                          let reply = await self.rpc("codeLens/resolve", params, language: language),
                          let updated = Self.parseResolvedCodeLens(from: reply, original: item.lens) else { return nil }
                    return (item.index, updated)
                }
            }
            var out: [(Int, CodeLens)] = []
            for await result in group { if let result { out.append(result) } }
            return out
        }
        for (index, lens) in resolved { lenses[index] = lens }
        return lenses.filter { $0.command != nil }
    }

    /// Parses `CodeLens[] | null`.
    static func parseCodeLenses(from data: Data) -> [CodeLens] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else { return [] }
        return result.compactMap(parseCodeLens)
    }

    static func parseCodeLens(_ entry: [String: Any]) -> CodeLens? {
        guard let range = entry["range"] as? [String: Any], let start = range["start"] as? [String: Any],
              let line = start["line"] as? Int, let character = start["character"] as? Int,
              let raw = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
        var lens = CodeLens(line: line, character: character, raw: raw)
        if let command = entry["command"] as? [String: Any], let name = command["command"] as? String {
            let args = (command["arguments"] as? [Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            lens.command = LSPCommand(command: name, arguments: args)
            lens.title = command["title"] as? String
        }
        return lens
    }

    /// Parses a `codeLens/resolve` reply, keeping the original's position.
    static func parseResolvedCodeLens(from data: Data, original: CodeLens) -> CodeLens? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              var lens = parseCodeLens(result), lens.command != nil else { return nil }
        lens.line = original.line
        lens.character = original.character
        return lens
    }

    /// Runs a lens's command on the server owning `fileURL`.
    func runCodeLens(_ lens: CodeLens, fileURL: URL) async {
        guard let command = lens.command else { return }
        await executeCommand(command, language: Language.detect(from: fileURL))
    }

    // MARK: - Call / type hierarchy

    /// `textDocument/prepareCallHierarchy` or `prepareTypeHierarchy`.
    func prepareHierarchy(fileURL: URL, line: Int, character: Int, types: Bool) async -> [HierarchyItem] {
        let language = Language.detect(from: fileURL)
        guard let caps = extraCapabilities[language], types ? caps.typeHierarchy : caps.callHierarchy else { return [] }
        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "position": ["line": line, "character": character],
        ]
        let method = types ? "textDocument/prepareTypeHierarchy" : "textDocument/prepareCallHierarchy"
        guard let data = await rpc(method, params, language: language) else { return [] }
        return Self.parseHierarchyItems(from: data)
    }

    /// Follows `direction` from `item`.
    func hierarchy(of item: HierarchyItem, direction: HierarchyDirection) async -> [HierarchyItem] {
        let language = Language.detect(from: item.fileURL)
        guard let raw = try? JSONSerialization.jsonObject(with: item.raw) as? [String: Any] else { return [] }
        let method: String
        switch direction {
        case .incomingCalls: method = "callHierarchy/incomingCalls"
        case .outgoingCalls: method = "callHierarchy/outgoingCalls"
        case .supertypes:    method = "typeHierarchy/supertypes"
        case .subtypes:      method = "typeHierarchy/subtypes"
        }
        guard let data = await rpc(method, ["item": raw], language: language) else { return [] }
        return direction.isCall ? Self.parseCallHierarchyCalls(from: data, direction: direction)
                                : Self.parseHierarchyItems(from: data)
    }

    /// Parses `CallHierarchyItem[] | TypeHierarchyItem[] | null`.
    static func parseHierarchyItems(from data: Data) -> [HierarchyItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else { return [] }
        return result.compactMap(parseHierarchyItem)
    }

    static func parseHierarchyItem(_ entry: [String: Any]) -> HierarchyItem? {
        guard let name = entry["name"] as? String, let kind = entry["kind"] as? Int,
              let uri = entry["uri"] as? String, let url = URL(string: uri),
              let raw = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
        let range = (entry["selectionRange"] as? [String: Any]) ?? (entry["range"] as? [String: Any])
        let start = range?["start"] as? [String: Any]
        return HierarchyItem(name: name, detail: entry["detail"] as? String, kind: kind, fileURL: url,
                             line: start?["line"] as? Int ?? 0, character: start?["character"] as? Int ?? 0, raw: raw)
    }

    /// Parses `CallHierarchyIncomingCall[]` (`from`) or `OutgoingCall[]` (`to`).
    static func parseCallHierarchyCalls(from data: Data, direction: HierarchyDirection) -> [HierarchyItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else { return [] }
        let key = direction == .incomingCalls ? "from" : "to"
        return result.compactMap { entry in
            guard let item = entry[key] as? [String: Any], var parsed = parseHierarchyItem(item) else { return nil }
            parsed.callSiteCount = (entry["fromRanges"] as? [Any])?.count ?? 0
            return parsed
        }
    }

    // MARK: - Linked editing

    /// `textDocument/linkedEditingRange` at a 0-based position.
    func linkedEditingRanges(fileURL: URL, line: Int, character: Int) async -> LinkedEditingRanges? {
        let language = Language.detect(from: fileURL)
        guard extraCapabilities[language]?.linkedEditing == true else { return nil }
        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "position": ["line": line, "character": character],
        ]
        guard let data = await rpc("textDocument/linkedEditingRange", params, language: language) else { return nil }
        return Self.parseLinkedEditingRanges(from: data)
    }

    /// Parses `LinkedEditingRanges | null`. Fewer than two ranges is nothing to mirror.
    static func parseLinkedEditingRanges(from data: Data) -> LinkedEditingRanges? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let raw = result["ranges"] as? [[String: Any]] else { return nil }
        let ranges: [LSPRangeSpan] = raw.compactMap { r in
            guard let s = r["start"] as? [String: Any], let e = r["end"] as? [String: Any],
                  let sl = s["line"] as? Int, let sc = s["character"] as? Int,
                  let el = e["line"] as? Int, let ec = e["character"] as? Int else { return nil }
            return LSPRangeSpan(startLine: sl, startCharacter: sc, endLine: el, endCharacter: ec)
        }
        guard ranges.count >= 2 else { return nil }
        return LinkedEditingRanges(ranges: ranges, wordPattern: result["wordPattern"] as? String)
    }

    // MARK: - File watching and file operations

    /// `workspace/didChangeWatchedFiles`: `type` 1 created, 2 changed, 3 deleted.
    /// Sent to every running server; servers ignore what they did not watch.
    func didChangeWatchedFiles(_ events: [(url: URL, type: Int)]) {
        guard !events.isEmpty else { return }
        let changes = events.map { ["uri": $0.url.absoluteString, "type": $0.type] as [String: Any] }
        for language in runningLanguages where extraCapabilities[language] != nil {
            notify("workspace/didChangeWatchedFiles", ["changes": changes], language: language)
        }
    }

    /// `workspace/willRenameFiles` against each server whose filters match
    /// any moved item; the returned edits are merged. Callers apply them
    /// before the move, since the edits address the old paths.
    func willRenameFiles(_ moves: [(old: URL, new: URL, isDirectory: Bool)]) async -> [URL: [LSPTextEdit]] {
        var merged: [URL: [LSPTextEdit]] = [:]
        for language in runningLanguages {
            guard let filters = extraCapabilities[language]?.willRenameFilters else { continue }
            let relevant = moves.filter { Self.fileOperationMatches(filters, path: $0.old.path, isDirectory: $0.isDirectory) }
            guard !relevant.isEmpty else { continue }
            let params: [String: Any] = ["files": relevant.map { ["oldUri": $0.old.absoluteString, "newUri": $0.new.absoluteString] }]
            guard let data = await rpc("workspace/willRenameFiles", params, language: language),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let edit = json["result"] as? [String: Any] else { continue }
            for (url, edits) in Self.workspaceEdits(from: edit) { merged[url, default: []] += edits }
        }
        return merged
    }

    /// `workspace/didRenameFiles` after the move happened.
    func didRenameFiles(_ moves: [(old: URL, new: URL, isDirectory: Bool)]) {
        for language in runningLanguages {
            guard let filters = extraCapabilities[language]?.didRenameFilters else { continue }
            let relevant = moves.filter { Self.fileOperationMatches(filters, path: $0.new.path, isDirectory: $0.isDirectory) }
            guard !relevant.isEmpty else { continue }
            let files = relevant.map { ["oldUri": $0.old.absoluteString, "newUri": $0.new.absoluteString] }
            notify("workspace/didRenameFiles", ["files": files], language: language)
        }
    }

    // MARK: - Source code actions (organize imports, fix all)

    /// `textDocument/codeAction` over the whole document restricted to `kind`
    /// (`source.organizeImports`, `source.fixAll`). Servers return sub-kinds
    /// too (`source.fixAll.ts`), so a prefix match is accepted.
    func sourceActions(fileURL: URL, kind: String, content: String) async -> [CodeAction] {
        let language = Language.detect(from: fileURL)
        guard extraCapabilities[language]?.codeActions == true else { return [] }
        let lines = content.components(separatedBy: "\n")
        let lastLine = max(lines.count - 1, 0)
        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "range": [
                "start": ["line": 0, "character": 0],
                "end": ["line": lastLine, "character": (lines.last ?? "").utf16.count],
            ],
            "context": [
                "diagnostics": allRawDiagnostics(for: fileURL),
                "only": [kind],
                "triggerKind": 1,
            ],
        ]
        guard let data = await rpc("textDocument/codeAction", params, language: language) else { return [] }
        return Self.filterActions(Self.parseCodeActions(from: data, language: language), kind: kind)
    }

    /// Keeps actions whose kind is `kind` or one of its dotted sub-kinds.
    static func filterActions(_ actions: [CodeAction], kind: String) -> [CodeAction] {
        actions.filter { action in
            guard let k = action.kind else { return false }
            return k == kind || k.hasPrefix(kind + ".")
        }
    }
}
