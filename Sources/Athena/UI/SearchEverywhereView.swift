// SearchEverywhereView.swift
// Athena — unified palette over files, workspace symbols, commands and text.
// Tabs (⇥ cycles) or a leading prefix pick the scope: ">" commands, "#"
// symbols, "%" text. Reuses QuickOpen's ranking and rows.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - Scope

enum SearchEverywhereScope: Int, CaseIterable, Sendable {
    case all, files, symbols, actions, text

    var title: String {
        switch self {
        case .all: return "All"
        case .files: return "Files"
        case .symbols: return "Symbols"
        case .actions: return "Actions"
        case .text: return "Text"
        }
    }

    /// Splits a typed query into its scope and search text. A prefix
    /// character forces a scope; otherwise `tab` decides.
    static func parse(_ query: String, tab: SearchEverywhereScope) -> (scope: SearchEverywhereScope, text: String) {
        guard let first = query.first else { return (tab, "") }
        let rest = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        switch first {
        case ">": return (.actions, rest)
        case "#": return (.symbols, rest)
        case "%": return (.text, rest)
        default:  return (tab, query)
        }
    }
}

// MARK: - Result

private enum SearchEverywhereHit: Identifiable {
    case file(QuickOpenEntry)
    case symbol(WorkspaceSymbol)
    case action(KeyBinding)
    case text(SearchResult)

    var id: String {
        switch self {
        case .file(let e):   return "f:" + e.id
        case .symbol(let s): return "s:" + s.id.uuidString
        case .action(let b): return "a:" + b.id
        case .text(let r):   return "t:" + r.id.uuidString
        }
    }
}

// MARK: - View

struct SearchEverywhereView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var tab: SearchEverywhereScope = .all
    @State private var selectedIndex = 0
    @State private var symbols: [WorkspaceSymbol] = []
    @State private var textResults: [SearchResult] = []
    @State private var matchCache = QuickOpenMatchCache()
    @State private var remoteTask: Task<Void, Never>?
    @State private var textService = SearchService()
    @FocusState private var searchFocused: Bool

    private static let sectionLimit = 6

    private var parsed: (scope: SearchEverywhereScope, text: String) {
        SearchEverywhereScope.parse(query, tab: tab)
    }

    private var hits: [SearchEverywhereHit] {
        let (scope, text) = parsed
        let limit = scope == .all ? Self.sectionLimit : 200
        var result: [SearchEverywhereHit] = []

        if scope == .all || scope == .files {
            let files = matchCache.matches(query: text, index: appState.quickOpenIndex, version: appState.quickOpenIndexVersion)
            result += files.prefix(limit).map { .file($0) }
        }
        if (scope == .all || scope == .actions), scope == .actions || !text.isEmpty {
            result += rankedActions(text).prefix(limit).map { .action($0) }
        }
        if (scope == .all || scope == .symbols), !text.isEmpty {
            result += symbols.prefix(limit).map { .symbol($0) }
        }
        if (scope == .all || scope == .text), text.count >= 3 {
            result += textResults.prefix(limit).map { .text($0) }
        }
        return result
    }

    private func rankedActions(_ text: String) -> [KeyBinding] {
        let all = appState.keyBindings
        guard !text.isEmpty else {
            return all.sorted { $0.action.displayName.localizedCompare($1.action.displayName) == .orderedAscending }
        }
        return all
            .compactMap { b -> (KeyBinding, Int)? in
                fuzzyNameScore(query: text, target: b.action.displayName).map { (b, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: appState.sf(8)) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: appState.sf(14)))
                    TextField("Search files, symbols, actions and text   (> actions  # symbols  % text)", text: $query)
                        .font(.system(size: appState.sf(16)))
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onKeyPress(.upArrow)   { move(-1); return .handled }
                        .onKeyPress(.downArrow) { move(1);  return .handled }
                        .onKeyPress(.tab)       { cycleTab(); return .handled }
                        .onKeyPress(.return)    { confirm(); return .handled }
                        .onKeyPress(.escape)    { close();   return .handled }
                }
                .padding(.horizontal, appState.sf(12))
                .padding(.vertical, appState.sf(10))

                HStack(spacing: appState.sf(6)) {
                    ForEach(SearchEverywhereScope.allCases, id: \.rawValue) { scope in
                        Text(scope.title)
                            .font(.system(size: appState.sf(11), weight: parsed.scope == scope ? .semibold : .regular))
                            .padding(.horizontal, appState.sf(8))
                            .padding(.vertical, appState.sf(2))
                            .background(parsed.scope == scope ? Color.accentColor.opacity(0.25) : Color.clear)
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                            .onTapGesture { tab = scope; query = parsedTextOnly }
                    }
                    Spacer()
                }
                .padding(.horizontal, appState.sf(12))
                .padding(.bottom, appState.sf(6))

                let list = hits
                if list.isEmpty {
                    Divider()
                    Text(parsed.text.isEmpty ? "Start typing to search" : "No results")
                        .foregroundStyle(.secondary)
                        .font(.system(size: appState.sf(12)))
                        .padding(appState.sf(20))
                } else {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, hit in
                                    row(for: hit, isSelected: i == selectedIndex)
                                        .id(hit.id)
                                        .onTapGesture { open(hit) }
                                }
                            }
                        }
                        .frame(maxHeight: appState.sf(380))
                        .onChange(of: selectedIndex) { _, idx in
                            guard list.indices.contains(idx) else { return }
                            proxy.scrollTo(list[idx].id, anchor: .center)
                        }
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: appState.sf(10)))
            .shadow(color: .black.opacity(0.5), radius: appState.sf(24), x: 0, y: appState.sf(12))
            .frame(width: appState.sf(620))
            .padding(.top, appState.sf(80))
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { selectedIndex = 0; scheduleRemoteSearch() }
        .onChange(of: tab) { selectedIndex = 0; scheduleRemoteSearch() }
        .onDisappear { remoteTask?.cancel(); Task { await textService.cancel() } }
    }

    /// The text without a scope prefix, so clicking a tab chip clears "> ".
    private var parsedTextOnly: String { parsed.text }

    @ViewBuilder
    private func row(for hit: SearchEverywhereHit, isSelected: Bool) -> some View {
        switch hit {
        case .file(let e):
            QuickOpenRow(name: e.name, relativeDirectory: e.relativeDirectory, isSelected: isSelected)
        case .symbol(let s):
            WorkspaceSymbolRow(symbol: s, isSelected: isSelected)
        case .action(let b):
            CommandPaletteRow(binding: b, isSelected: isSelected)
        case .text(let r):
            TextHitRow(result: r, isSelected: isSelected)
        }
    }

    // MARK: - Remote (symbols, text)

    /// Debounced; a stale reply never replaces newer results.
    private func scheduleRemoteSearch() {
        remoteTask?.cancel()
        let (scope, text) = parsed
        let wantSymbols = (scope == .all || scope == .symbols) && !text.isEmpty
        let wantText = (scope == .all || scope == .text) && text.count >= 3
        if !wantSymbols { symbols = [] }
        if !wantText { textResults = [] }
        guard wantSymbols || wantText else { return }

        let manager = appState.lspManager
        let service = textService
        let root = appState.workspace?.rootURL
        remoteTask = Task {
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(180)))
            guard !Task.isCancelled else { return }
            if wantSymbols {
                let found = await manager.workspaceSymbols(query: text)
                guard !Task.isCancelled else { return }
                symbols = Array(found.prefix(200))
            }
            if wantText, let root {
                await service.cancel()
                var collected: [SearchResult] = []
                let stream = await service.search(query: text, in: root, regex: false, caseSensitive: false)
                for await hit in stream {
                    if Task.isCancelled { break }
                    collected.append(hit)
                    if collected.count >= 100 { break }
                }
                guard !Task.isCancelled else { return }
                textResults = collected
            }
        }
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let count = hits.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func cycleTab() {
        let all = SearchEverywhereScope.allCases
        let next = all[(parsed.scope.rawValue + 1) % all.count]
        tab = next
        query = parsed.text
    }

    private func confirm() {
        let list = hits
        guard list.indices.contains(selectedIndex) else { return }
        open(list[selectedIndex])
    }

    private func open(_ hit: SearchEverywhereHit) {
        switch hit {
        case .file(let e):
            Task { await appState.openFile(e.file.url) }
        case .symbol(let s):
            Task { await appState.navigateTo(s.location) }
        case .action(let b):
            Task { await appState.perform(b.action) }
        case .text(let r):
            Task { await appState.navigateToReference(r) }
        }
        close()
    }

    private func close() {
        remoteTask?.cancel()
        appState.showSearchEverywhere = false
    }
}

// MARK: - Text row

private struct TextHitRow: View {
    let result: SearchResult
    let isSelected: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: appState.sf(8)) {
            Image(systemName: "text.alignleft")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: appState.sf(14))
            VStack(alignment: .leading, spacing: appState.sf(1)) {
                Text(result.lineContent.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: appState.sf(13)))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                Text("\(URL(fileURLWithPath: result.filePath).lastPathComponent):\(result.lineNumber)")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(isSelected ? .white.opacity(0.65) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, appState.sf(12))
        .padding(.vertical, appState.sf(6))
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}
