// AppState+InlineCompletion.swift
// Athena — ghost text: chooses the provider, gathers context, enforces the
// cloud limits, and streams suggestions to the editor.
// Swift 6, strict concurrency.

import Foundation

extension AppState {

    // MARK: - Streaming entry point

    /// Streams ghost-text events for one editor query in `tab`. Cancelling
    /// the consumer cancels context gathering and the network request.
    func inlineCompletionStream(_ query: InlineCompletionQuery, tab: TabModel) -> AsyncStream<InlineCompletionEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                await self?.runInlineCompletion(query, tab: tab, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runInlineCompletion(
        _ query: InlineCompletionQuery,
        tab: TabModel,
        continuation: AsyncStream<InlineCompletionEvent>.Continuation
    ) async {
        guard let backend = inlineBackend(), isGhostTextAllowed(in: tab) else { return }
        let isCloud: Bool
        if case .claude = backend { isCloud = true } else { isCloud = false }

        var request = InlineCompletionRequest(
            prefix: query.prefix, suffix: query.suffix, mode: query.mode, variant: query.variant,
            path: inlinePath(for: tab), language: tab.language, header: "", snippets: []
        )
        let config = InlineCompletionService.Config(
            backend: backend,
            temperature: ghostTextTemperature,
            maxTokens: ghostTextMaxTokens,
            repoName: workspace?.rootURL.lastPathComponent ?? "workspace"
        )

        // A cached answer costs nothing — check before limits and context.
        if let hit = await inlineCompletionService.cachedSuggestion(for: request, backend: backend) {
            continuation.yield(.finished(hit))
            return
        }
        if isCloud, await !admitCloudRequest() { return }
        guard !Task.isCancelled else { return }

        inlineCompletionsInFlight += 1
        defer { inlineCompletionsInFlight -= 1 }

        let context = await gatherInlineContext(for: query, in: tab, cloud: isCloud)
        guard !Task.isCancelled else { return }
        request.header = context.header
        request.snippets = context.snippets

        for await event in inlineCompletionService.stream(request, config: config) {
            switch event {
            case .failed(let message):
                if statusMessage != message { statusMessage = message }
            case .rateLimited(let until):
                cloudBackoffUntil = until
            case .text, .finished:
                break
            }
            continuation.yield(event)
        }
    }

    /// The configured provider, or `nil` when ghost text is off or not set up.
    func inlineBackend() -> InlineCompletionService.Backend? {
        switch ghostTextProvider {
        case .none:
            return nil
        case .claude:
            guard !claudeAPIKey.isEmpty else {
                let message = "Claude ghost text needs an API key (Settings → AI)."
                if statusMessage != message { statusMessage = message }
                return nil
            }
            return .claude(apiKey: claudeAPIKey)
        case .ollama:
            return .ollama(
                endpoint: ollamaEndpoint.isEmpty ? Self.defaultOllamaEndpoint : ollamaEndpoint,
                model: ollamaModel.isEmpty ? Self.defaultOllamaModel : ollamaModel
            )
        case .openAICompatible:
            guard !localOAIEndpoint.isEmpty, !localOAIModel.isEmpty else { return nil }
            return .openAICompatible(endpoint: localOAIEndpoint, model: localOAIModel, apiKey: localOAIAPIKey)
        }
    }

    /// Never in secrets (nothing from them may reach a model), never in
    /// lockfiles or minified bundles, and not in languages the user turned off.
    func isGhostTextAllowed(in tab: TabModel) -> Bool {
        let path = tab.fileURL?.path ?? tab.title
        if InlineContextRanker.isSensitive(path: path) { return false }
        if InlineContextRanker.isNoise(path: path, length: tab.content.utf16.count) { return false }
        return !ghostTextDisabledLanguages.contains(tab.language.rawValue)
    }

    // MARK: - Cloud limits

    /// Backoff after a 429/529, the daily cap, and a minimum gap between
    /// cloud requests so a short debounce can't turn every pause into a
    /// paid call. Counts the request when it's admitted.
    private func admitCloudRequest() async -> Bool {
        let now = Date()
        if let until = cloudBackoffUntil, until > now { return false }

        let today = Self.dayStamp(now)
        if ghostTextCloudUsage.day != today { ghostTextCloudUsage = GhostTextCloudUsage(day: today, count: 0) }
        if ghostTextCloudDailyLimit > 0, ghostTextCloudUsage.count >= ghostTextCloudDailyLimit {
            let message = "Claude ghost text paused: today's limit of \(ghostTextCloudDailyLimit) requests is reached (Settings → AI)."
            if statusMessage != message { statusMessage = message }
            return false
        }

        let minimumGap: TimeInterval = 0.4
        if let last = lastCloudRequestAt, now.timeIntervalSince(last) < minimumGap {
            let wait = minimumGap - now.timeIntervalSince(last)
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(Int(wait * 1000))))
            if Task.isCancelled { return false }
        }

        lastCloudRequestAt = Date()
        ghostTextCloudUsage.count += 1
        persistSetting(ghostTextCloudUsage, for: "ghostTextCloudUsage")
        return true
    }

    nonisolated static func dayStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Stats

    func recordGhostTextShown() { ghostTextShownCount += 1 }
    func recordGhostTextAccepted() { ghostTextAcceptedCount += 1 }

    // MARK: - Context

    /// What the model sees beyond the text around the caret, cheapest and
    /// most precise first: language-server definitions of symbols just
    /// used, outlines of imported files, then the most similar code in
    /// open tabs — all within the provider's budget. Other files go to the
    /// cloud only when the user allowed it.
    func gatherInlineContext(
        for query: InlineCompletionQuery,
        in tab: TabModel,
        cloud: Bool
    ) async -> (header: String, snippets: [InlineContextSnippet]) {
        guard includeGhostTextContext else { return ("", []) }
        let header = inlineHeader(for: query, in: tab)
        guard !cloud || ghostTextShareContextWithCloud else { return (header, []) }

        let budget = (cloud ? InlinePromptBuilder.Window.cloud : .local).contextChars
        var snippets: [InlineContextSnippet] = []
        var used = 0
        func add(_ snippet: InlineContextSnippet) {
            let cost = snippet.text.count + snippet.path.count
            guard !snippet.text.isEmpty, used + cost <= budget, !snippets.contains(snippet) else { return }
            snippets.append(snippet)
            used += cost
        }

        for snippet in await definitionSnippets(for: query, in: tab) { add(snippet) }
        guard !Task.isCancelled else { return (header, snippets) }
        for snippet in await importOutlines(for: query, in: tab) { add(snippet) }
        guard !Task.isCancelled else { return (header, snippets) }

        let documents: [(path: String, text: String)] = openTabs
            .filter { $0.id != tab.id && $0.fileURL != nil && $0.fileURL != tab.fileURL }
            .compactMap { other in
                guard let url = other.fileURL,
                      !InlineContextRanker.isSensitive(path: url.path),
                      !InlineContextRanker.isNoise(path: url.path, length: other.content.utf16.count)
                else { return nil }
                return (relativePath(of: url), other.content)
            }
        let queryText = query.prefix.components(separatedBy: "\n").suffix(20).joined(separator: "\n")
        let remaining = budget - used
        if remaining > 200, !documents.isEmpty {
            let windows = await Task.detached(priority: .userInitiated) {
                InlineContextRanker.bestWindows(query: queryText, documents: Array(documents.prefix(12)), maxChars: remaining)
            }.value
            for snippet in windows { add(snippet) }
        }
        return (header, snippets)
    }

    /// The file's imports and the symbol the caret is inside — sent when
    /// the prefix window no longer reaches the top of the file.
    private func inlineHeader(for query: InlineCompletionQuery, in tab: TabModel) -> String {
        var lines: [String] = []
        let imports = importLines(in: query.prefix + query.suffix).prefix(8)
        if !imports.isEmpty { lines.append("imports:\n\(imports.joined(separator: "\n"))") }
        // `documentSymbols` tracks the focused tab only.
        if tab.id == focusedTab?.id {
            let line = query.prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let path = breadcrumbSymbolPath(in: documentSymbols, containingLine: line).map(\.name).joined(separator: ".")
            if !path.isEmpty { lines.append("inside: \(path)") }
        }
        return String(lines.joined(separator: "\n").prefix(500))
    }

    /// Definitions of the identifiers just typed, from the language server,
    /// waiting at most 150 ms. Lookups that finish later are cached, so the
    /// next request at a nearby caret gets them.
    private func definitionSnippets(for query: InlineCompletionQuery, in tab: TabModel) async -> [InlineContextSnippet] {
        guard let fileURL = tab.fileURL else { return [] }
        let identifiers = InlineContextRanker.identifiersNearCaret(prefix: query.prefix)
        let now = Date()
        let key: (String) -> String = { "\(fileURL.path)#\($0)" }

        var tasks: [Task<Void, Never>] = []
        for id in identifiers {
            if let cached = definitionSnippetCache[key(id.name)], now.timeIntervalSince(cached.at) < 60 { continue }
            // Mark as in progress so overlapping requests don't re-ask.
            definitionSnippetCache[key(id.name)] = (nil, now)
            let lsp = lspManager
            tasks.append(Task { @MainActor [weak self] in
                let location = try? await lsp.definition(fileURL: fileURL, line: id.line - 1, character: id.column - 1)
                var snippet: InlineContextSnippet?
                if let location, location.fileURL != fileURL,
                   !InlineContextRanker.isSensitive(path: location.fileURL.path),
                   let text = await Self.readLines(of: location.fileURL, from: location.line, count: 8) {
                    snippet = InlineContextSnippet(path: self?.relativePath(of: location.fileURL) ?? location.fileURL.lastPathComponent, text: text)
                }
                self?.definitionSnippetCache[key(id.name)] = (snippet, Date())
            })
        }
        if !tasks.isEmpty { await Self.waitAtMost(milliseconds: 150, for: tasks) }

        if definitionSnippetCache.count > 400 { definitionSnippetCache.removeAll() }
        return identifiers.compactMap { definitionSnippetCache[key($0.name)]?.snippet }
    }

    /// Declaration outlines of the local files this file imports.
    private func importOutlines(for query: InlineCompletionQuery, in tab: TabModel) async -> [InlineContextSnippet] {
        guard let fileURL = tab.fileURL else { return [] }
        var result: [InlineContextSnippet] = []
        for spec in InlineContextRanker.importSpecifiers(in: query.prefix + query.suffix) {
            guard !Task.isCancelled else { break }
            guard let url = await importResolver.resolve(spec, from: fileURL, workspaceURL: workspace?.rootURL),
                  !InlineContextRanker.isSensitive(path: url.path)
            else { continue }
            let cached = importOutlineCache[url.path]
            let loaded = await Task.detached(priority: .userInitiated) { () -> (modified: Date, outline: String)? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let modified = attrs[.modificationDate] as? Date else { return nil }
                if let cached, cached.modified == modified { return cached }
                guard (attrs[.size] as? Int ?? 0) < 1_000_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (modified, InlineContextRanker.outline(of: text))
            }.value
            guard let loaded else { continue }
            importOutlineCache[url.path] = loaded
            if !loaded.outline.isEmpty {
                result.append(InlineContextSnippet(path: relativePath(of: url), text: loaded.outline))
            }
        }
        return result
    }

    // MARK: - Helpers

    func inlinePath(for tab: TabModel) -> String {
        tab.fileURL.map { relativePath(of: $0) } ?? tab.title
    }

    func relativePath(of url: URL) -> String {
        if let root = workspace?.rootURL.path, url.path.hasPrefix(root + "/") {
            return String(url.path.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    /// `count` lines of `url` starting at 1-based `line`, read off the main thread.
    nonisolated static func readLines(of url: URL, from line: Int, count: Int) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lines = text.components(separatedBy: "\n")
            let start = max(0, line - 1)
            guard start < lines.count else { return nil }
            return lines[start..<min(start + count, lines.count)].joined(separator: "\n")
        }.value
    }

    /// Returns when every task has finished or `milliseconds` have passed,
    /// whichever is first. The tasks keep running either way.
    nonisolated static func waitAtMost(milliseconds: Int, for tasks: [Task<Void, Never>]) async {
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        let waiter = Task {
            for task in tasks { await task.value }
            continuation.yield(())
        }
        let timer = Task {
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(milliseconds)))
            continuation.yield(())
        }
        var iterator = signal.makeAsyncIterator()
        _ = await iterator.next()
        waiter.cancel()
        timer.cancel()
        continuation.finish()
    }

    /// Fetches installed Ollama model names for the Settings "Fetch models"
    /// button — falls back to the free-text field when empty.
    func fetchOllamaModels() async -> [String] {
        let endpoint = ollamaEndpoint.isEmpty ? Self.defaultOllamaEndpoint : ollamaEndpoint
        return await inlineCompletionService.fetchOllamaModels(endpoint: endpoint)
    }

    /// Whether the selected Ollama model can fill in the middle — Settings
    /// warns when it can't (a chat model rather than a code model).
    func ollamaModelCapabilities() async -> InlineCompletionService.OllamaCapabilities {
        let endpoint = ollamaEndpoint.isEmpty ? Self.defaultOllamaEndpoint : ollamaEndpoint
        let model = ollamaModel.isEmpty ? Self.defaultOllamaModel : ollamaModel
        return await inlineCompletionService.ollamaCapabilities(endpoint: endpoint, model: model)
    }
}
