// QuickOpenView.swift
// Athena — ⌘P file-search palette + ⇧⌘P command palette (VS Code parity).
// A leading ">" switches the same palette into command mode, "@" into
// ⇧⌘O "Go to Symbol" mode.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

// MARK: - Fuzzy matching

/// VS Code–style fuzzy match: every character of `query` must appear in
/// order (not necessarily contiguously) in `target`, case-insensitive.
/// Returns `nil` on no match; otherwise a score where higher is better, so
/// e.g. "sfcclv" ranks "SFCCLogView.swift" above a file that merely
/// contains those letters scattered apart. Matches right after a path/word
/// boundary, or in an unbroken run, score highest.
private func fuzzyScore(query: String, target: String) -> Int? {
    guard !query.isEmpty else { return 0 }
    let queryChars = Array(query.lowercased())
    let targetChars = Array(target)
    var qi = 0
    var score = 0
    var consecutiveRun = 0

    for (ti, ch) in targetChars.enumerated() {
        guard qi < queryChars.count else { break }
        guard Character(ch.lowercased()) == queryChars[qi] else {
            consecutiveRun = 0
            continue
        }
        var bonus = 1
        if ti == 0 {
            bonus += 8
        } else {
            let prev = targetChars[ti - 1]
            if "/_-. ".contains(prev) || (prev.isLowercase && ch.isUppercase) {
                bonus += 6
            }
        }
        consecutiveRun += 1
        bonus += min(consecutiveRun, 5)
        score += bonus
        qi += 1
    }

    return qi == queryChars.count ? score : nil
}

// MARK: - QuickOpenView

struct QuickOpenView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool

    // MARK: - Mode

    /// Typing ">" as the first character switches the palette into command mode.
    private var isCommandMode: Bool { query.hasPrefix(">") }

    private var commandQuery: String {
        String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Typing "@" as the first character switches the palette into "Go to
    /// Symbol" mode (⇧⌘O, VS Code parity — `@` lists symbols in the current
    /// file). Mutually exclusive with command mode: both check only the
    /// first character, so only one can match at a time.
    private var isSymbolMode: Bool { query.hasPrefix("@") }

    private var symbolQuery: String {
        String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private var placeholderText: String {
        if isCommandMode { return "Type a command…" }
        if isSymbolMode  { return "Go to symbol…" }
        return "Go to file…"
    }

    // MARK: - Filtered results

    private var commandResults: [KeyBinding] {
        let q = commandQuery
        let all = appState.keyBindings
        guard !q.isEmpty else {
            return all.sorted { $0.action.displayName.localizedCompare($1.action.displayName) == .orderedAscending }
        }
        return all
            .compactMap { binding -> (KeyBinding, Int)? in
                guard let score = fuzzyScore(query: q, target: binding.action.displayName) else { return nil }
                return (binding, score)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.action.displayName.localizedCompare(b.0.action.displayName) == .orderedAscending
            }
            .map(\.0)
    }

    /// The active tab's document symbols, flattened depth-first (see
    /// `flattenDocumentSymbols`) and filtered by name — the flat list keeps
    /// filtering simple while `depth` (rendered as indentation by
    /// `SymbolPaletteRow`) keeps the hierarchy visible.
    private var symbolResults: [(symbol: DocumentSymbol, depth: Int)] {
        let flattened = flattenDocumentSymbols(appState.documentSymbols)
        let q = symbolQuery
        guard !q.isEmpty else { return flattened }
        return flattened
            .compactMap { entry -> ((symbol: DocumentSymbol, depth: Int), Int)? in
                guard let score = fuzzyScore(query: q, target: entry.symbol.name) else { return nil }
                return (entry, score)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.symbol.name.localizedCompare(b.0.symbol.name) == .orderedAscending
            }
            .map(\.0)
    }

    private var results: [FileNode] {
        let all = appState.allFiles
        guard !query.isEmpty else { return Array(all.prefix(200)) }
        return all
            .compactMap { file -> (FileNode, Int)? in
                guard let score = fuzzyScore(query: query, target: file.url.path) else { return nil }
                return (file, score)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.name.localizedCompare(b.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop — tap to dismiss
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            // Palette card
            VStack(spacing: 0) {
                // Search field row
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: appState.sf(14)))

                    TextField(placeholderText, text: $query)
                        .font(.system(size: appState.sf(16)))
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        // Arrow keys — navigate the list
                        .onKeyPress(.upArrow)   { move(-1); return .handled }
                        .onKeyPress(.downArrow) { move(1);  return .handled }
                        // Return — open the selected file / run the selected command
                        .onKeyPress(.return)    { confirmSelection(); return .handled }
                        // Escape — dismiss
                        .onKeyPress(.escape)    { close(); return .handled }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                // Results or empty state — each mode's filtered list is computed
                // once into `matches` and reused for the empty-check and the
                // ForEach; the naive version called the filtering computed
                // property up to 3x per render, which visibly lagged behind
                // typing on large workspaces (SFCC checkouts especially).
                if isCommandMode {
                    let matches = commandResults
                    if matches.isEmpty {
                        Divider()
                        Text("No matching commands")
                            .foregroundStyle(.secondary)
                            .font(.system(size: appState.sf(12)))
                            .padding(20)
                    } else {
                        Divider()
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(
                                        Array(matches.prefix(200).enumerated()),
                                        id: \.element.id
                                    ) { i, binding in
                                        CommandPaletteRow(
                                            binding: binding,
                                            isSelected: i == selectedIndex
                                        )
                                        .id(i)
                                        .onTapGesture { invoke(binding.action) }
                                    }
                                }
                            }
                            .frame(maxHeight: 360)
                            .onChange(of: selectedIndex) { _, idx in
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                } else if isSymbolMode {
                    let matches = symbolResults
                    if matches.isEmpty {
                        Divider()
                        Text("No matching symbols")
                            .foregroundStyle(.secondary)
                            .font(.system(size: appState.sf(12)))
                            .padding(20)
                    } else {
                        Divider()
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(
                                        Array(matches.prefix(200).enumerated()),
                                        id: \.element.symbol.id
                                    ) { i, entry in
                                        SymbolPaletteRow(
                                            symbol: entry.symbol,
                                            depth: entry.depth,
                                            isSelected: i == selectedIndex
                                        )
                                        .id(i)
                                        .onTapGesture { selectSymbol(entry.symbol) }
                                    }
                                }
                            }
                            .frame(maxHeight: 360)
                            .onChange(of: selectedIndex) { _, idx in
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                } else {
                    let matches = results
                    if matches.isEmpty && !query.isEmpty {
                        Divider()
                        Text("No results for \"\(query)\"")
                            .foregroundStyle(.secondary)
                            .font(.system(size: appState.sf(12)))
                            .padding(20)
                    } else if !matches.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(
                                    Array(matches.prefix(200).enumerated()),
                                    id: \.element.id
                                ) { i, file in
                                    QuickOpenRow(
                                        file: file,
                                        isSelected: i == selectedIndex,
                                        workspaceURL: appState.workspace?.rootURL
                                    )
                                    .id(i)
                                    .onTapGesture { open(file) }
                                }
                            }
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: selectedIndex) { _, idx in
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
            .frame(width: 580)
            .padding(.top, 80)
        }
        .onAppear {
            query = appState.quickOpenPrefill
            searchFocused = true
        }
        .onChange(of: query) { selectedIndex = 0 }
    }

    // MARK: - Actions

    private var currentResultCount: Int {
        if isCommandMode { return min(commandResults.count, 200) }
        if isSymbolMode  { return min(symbolResults.count, 200) }
        return min(results.count, 200)
    }

    private func move(_ delta: Int) {
        let count = currentResultCount
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func confirmSelection() {
        if isCommandMode {
            guard selectedIndex < commandResults.count else { return }
            invoke(commandResults[selectedIndex].action)
        } else if isSymbolMode {
            guard selectedIndex < symbolResults.count else { return }
            selectSymbol(symbolResults[selectedIndex].symbol)
        } else {
            guard selectedIndex < results.count else { return }
            open(results[selectedIndex])
        }
    }

    private func open(_ file: FileNode) {
        Task { await appState.openFile(file.url) }
        close()
    }

    private func invoke(_ action: KeyAction) {
        Task { await appState.perform(action) }
        close()
    }

    /// Jumps to `symbol` in the active tab's file via the same
    /// `AppState.navigateTo`/`EditorScrollProxy.jumpTo` cross-view navigation
    /// path Find All References and Rename Symbol already use — no separate
    /// jump implementation for Go to Symbol.
    private func selectSymbol(_ symbol: DocumentSymbol) {
        if let fileURL = appState.focusedTab?.fileURL {
            Task {
                await appState.navigateTo(
                    DefinitionLocation(fileURL: fileURL, line: symbol.line, character: symbol.character)
                )
            }
        }
        close()
    }

    private func close() {
        appState.showQuickOpen = false
    }
}

// MARK: - Row

private struct QuickOpenRow: View {
    let file: FileNode
    let isSelected: Bool
    let workspaceURL: URL?
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: appState.sf(13)))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                if let rel = relativePath {
                    Text(rel)
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(isSelected ? .white.opacity(0.65) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }

    private var relativePath: String? {
        guard let root = workspaceURL else { return nil }
        let dir = file.url.deletingLastPathComponent().path
        guard dir.hasPrefix(root.path) else { return nil }
        let rel = String(dir.dropFirst(root.path.count))
        let trimmed = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Command palette row

private struct CommandPaletteRow: View {
    let binding: KeyBinding
    let isSelected: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(binding.action.displayName)
                    .font(.system(size: appState.sf(13)))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text(binding.action.category)
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(isSelected ? .white.opacity(0.65) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let combo = binding.combo {
                Text(combo.displayString)
                    .font(.system(size: appState.sf(11), weight: .medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Symbol palette row (Go to Symbol, ⇧⌘O)

private struct SymbolPaletteRow: View {
    let symbol: DocumentSymbol
    let depth: Int
    let isSelected: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

            Image(systemName: symbol.iconName)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: 14)

            Text(symbol.name)
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}
