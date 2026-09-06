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
/// boundary, or in an unbroken run, score highest. For ranked lists of
/// names prefer `fuzzyNameScore`, which adds the prefix/substring bonuses.
///
/// Matching is greedy (each query character binds to its first eligible
/// occurrence), so callers must not hand it a long shared prefix — see
/// `quickOpenScore` for why ⌘P scores the filename before the path.
func fuzzyScore(query: String, target: String) -> Int? {
    fuzzyScore(loweredQuery: FuzzyQuery(query).scalars, target: target)
}

/// A query lowercased once, so ⌘P doesn't re-lowercase it per candidate
/// (that alone was 60k allocations per keystroke on a large workspace).
struct FuzzyQuery {
    let raw: String
    let lowered: String
    let scalars: [Unicode.Scalar]
    let containsSlash: Bool

    init(_ query: String) {
        raw = query
        lowered = query.lowercased()
        scalars = Array(lowered.unicodeScalars)
        containsSlash = query.contains("/")
    }
}

private let fuzzyBoundaryScalars: Set<Unicode.Scalar> = Set("/_-. ".unicodeScalars)

/// ASCII fast path; anything else goes through the String machinery, which
/// only happens for non-ASCII path segments.
@inline(__always)
private func fuzzyLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    if scalar.value >= 65 && scalar.value <= 90 { return Unicode.Scalar(scalar.value + 32)! }
    if scalar.value < 128 { return scalar }
    return String(scalar).lowercased().unicodeScalars.first ?? scalar
}

/// Core matcher over `target.unicodeScalars` — no per-call arrays, so
/// scoring every file in a workspace on each keystroke stays allocation-free.
func fuzzyScore(loweredQuery: [Unicode.Scalar], target: String) -> Int? {
    guard !loweredQuery.isEmpty else { return 0 }
    var qi = 0
    var score = 0
    var consecutiveRun = 0
    var prev: Unicode.Scalar? = nil

    for ch in target.unicodeScalars {
        if qi == loweredQuery.count { break }
        if fuzzyLowercased(ch) == loweredQuery[qi] {
            var bonus = 1
            if let prev {
                if fuzzyBoundaryScalars.contains(prev)
                    || (prev.properties.isLowercase && ch.properties.isUppercase) {
                    bonus += 6
                }
            } else {
                bonus += 8
            }
            consecutiveRun += 1
            bonus += min(consecutiveRun, 5)
            score += bonus
            qi += 1
        } else {
            consecutiveRun = 0
        }
        prev = ch
    }

    return qi == loweredQuery.count ? score : nil
}

/// ⌘P ranking for one workspace file. `relativePath` is the path below the
/// workspace root (e.g. "cartridges/app_ana/cartridge/controllers/Cart.js"),
/// never an absolute path: `fuzzyScore` is greedy, so given absolute paths
/// the query letters get consumed by the shared "/Users/…/Sites/…" prefix
/// and by directory names, and every file in the workspace ties (typing
/// "cart" scored Cart.js, cart.isml and base.js identically, leaving the
/// list in alphabetical order — i.e. not matching by filename at all).
///
/// Filename first, path second, mirroring VS Code: a query without "/" is
/// scored against the file's name and, on a hit, gets a flat bonus that no
/// path-only match can reach, plus extra for an exact / prefix / contiguous
/// name match. Only if the name doesn't match (or the query contains "/")
/// does the full relative path get scored, so "anacart" can still reach
/// app_ana/…/Cart.js through its directories.
func quickOpenScore(_ query: FuzzyQuery, entry: QuickOpenEntry) -> Int? {
    guard !query.scalars.isEmpty else { return 0 }

    if !query.containsSlash, let nameScore = fuzzyScore(loweredQuery: query.scalars, target: entry.name) {
        return 1_000 + nameScore * 4 + nameMatchBonus(loweredName: entry.loweredName, loweredQuery: query.lowered)
    }

    return fuzzyScore(loweredQuery: query.scalars, target: entry.relativePath)
}

/// Exact > prefix > contiguous substring. Without this, `fuzzyScore`'s
/// boundary bonuses rank a camel-case scatter ("toString" for "st") above a
/// plain prefix ("startsWith") — wrong for filenames, commands, symbols and
/// completion items alike.
func nameMatchBonus(loweredName: String, loweredQuery: String) -> Int {
    if loweredName == loweredQuery { return 400 }
    if loweredName.hasPrefix(loweredQuery) { return 200 }
    if loweredName.contains(loweredQuery) { return 100 }
    return 0
}

/// `fuzzyScore` for a short name (command title, symbol, completion label)
/// with the prefix/substring bonuses folded in. Use this, not bare
/// `fuzzyScore`, whenever the results are shown ranked.
func fuzzyNameScore(query: String, target: String) -> Int? {
    let fuzzy = FuzzyQuery(query)
    guard let base = fuzzyScore(loweredQuery: fuzzy.scalars, target: target) else { return nil }
    return base + nameMatchBonus(loweredName: target.lowercased(), loweredQuery: fuzzy.lowered)
}

/// One ⌘P candidate: the file plus its workspace-relative path and the
/// name-derived fields the ranker needs, all computed once when the index
/// is built (`AppState.quickOpenIndex`) rather than per keystroke per file
/// (`FileNode.name` re-parses the URL on every access, which dominated the
/// sort).
struct QuickOpenEntry: Identifiable, Sendable {
    let file: FileNode
    let relativePath: String
    let name: String
    let loweredName: String
    let nameLength: Int
    var id: String { file.id }

    init(file: FileNode, relativePath: String) {
        self.file = file
        self.relativePath = relativePath
        let nameStart = relativePath.lastIndex(of: "/")
            .map { relativePath.index(after: $0) } ?? relativePath.startIndex
        name = String(relativePath[nameStart...])
        loweredName = name.lowercased()
        nameLength = name.unicodeScalars.count
    }

    /// Directory part of `relativePath` for the row's secondary line; `nil`
    /// for files directly under the workspace root.
    var relativeDirectory: String? {
        guard let slash = relativePath.lastIndex(of: "/") else { return nil }
        let dir = relativePath[..<slash]
        return dir.isEmpty ? nil : String(dir)
    }
}

/// Flattens the workspace tree into ⌘P candidates, sorted by relative path
/// so the empty-query listing and tie-breaking are just array order (no
/// per-keystroke string sorts). URLs in the tree come from listing the
/// symlink-resolved root (see `FileService.buildFileTree`), so the root is
/// matched both as given and resolved (`/tmp` vs `/private/tmp`, a
/// symlinked checkout); a file under neither keeps its absolute path rather
/// than being dropped from the index. Pure and `Sendable`-only, so
/// `AppState` runs it off the main thread.
func makeQuickOpenIndex(fileTree: [FileNode], workspaceRootURL: URL?) -> [QuickOpenEntry] {
    var prefixes: [String] = []
    if let root = workspaceRootURL {
        let given = root.standardizedFileURL.path
        let resolved = root.resolvingSymlinksInPath().path
        prefixes = [given + "/", resolved + "/"]
    }

    var result: [QuickOpenEntry] = []
    func collect(_ nodes: [FileNode]) {
        for node in nodes {
            if !node.isDirectory {
                let path = node.url.path
                let relative = prefixes.first { path.hasPrefix($0) }
                    .map { String(path.dropFirst($0.count)) } ?? path
                result.append(QuickOpenEntry(file: node, relativePath: relative))
            }
            if let children = node.children { collect(children) }
        }
    }
    collect(fileTree)
    result.sort { $0.relativePath < $1.relativePath }
    return result
}

/// Filters and ranks `index` (as produced by `makeQuickOpenIndex`, i.e.
/// path-sorted) for `query`, returning at most `limit` entries. An empty
/// query lists the index in path order; otherwise higher `quickOpenScore`
/// first, then the shorter filename (the more specific hit), then index
/// order for stability. The comparator is integer-only on purpose: with a
/// short query most of a large workspace ties on score, and breaking those
/// ties by comparing long path strings was the bulk of each keystroke.
func rankQuickOpenEntries(_ index: [QuickOpenEntry], query: String, limit: Int = 200) -> [QuickOpenEntry] {
    guard !query.isEmpty else { return Array(index.prefix(limit)) }
    let fuzzyQuery = FuzzyQuery(query)
    var scored: [(position: Int, nameLength: Int, score: Int)] = []
    scored.reserveCapacity(index.count / 4)
    for (position, entry) in index.enumerated() {
        if let score = quickOpenScore(fuzzyQuery, entry: entry) {
            scored.append((position, entry.nameLength, score))
        }
    }
    scored.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        if a.nameLength != b.nameLength { return a.nameLength < b.nameLength }
        return a.position < b.position
    }
    return scored.prefix(limit).map { index[$0.position] }
}

/// Memoizes one ranked list for a `(query, index version)` pair.
///
/// A reference type deliberately: the view's body, its key handlers and its
/// row taps must all agree on exactly what is on screen, and mutating a
/// class held in `@State` doesn't invalidate the view (so it is safe to
/// call while the body is being evaluated). Ranking used to be cached in a
/// `@State` array refreshed from `onChange(of: query)`, which left the
/// list one keystroke behind the field.
@MainActor final class QuickOpenMatchCache {
    private var key: (query: String, version: Int)?
    private var cached: [QuickOpenEntry] = []

    func matches(query: String, index: [QuickOpenEntry], version: Int) -> [QuickOpenEntry] {
        if let key, key.query == query, key.version == version { return cached }
        cached = rankQuickOpenEntries(index, query: query)
        key = (query, version)
        return cached
    }
}

// MARK: - QuickOpenView

struct QuickOpenView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var matchCache = QuickOpenMatchCache()
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
                guard let score = fuzzyNameScore(query: q, target: binding.action.displayName) else { return nil }
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
                guard let score = fuzzyNameScore(query: q, target: entry.symbol.name) else { return nil }
                return (entry, score)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.symbol.name.localizedCompare(b.0.symbol.name) == .orderedAscending
            }
            .map(\.0)
    }

    /// Ranked files for the current query. Reading `quickOpenIndex` and
    /// `quickOpenIndexVersion` here is what subscribes the body to a
    /// finished index rebuild; `matchCache` keeps that to one ranking pass
    /// per keystroke rather than one per render.
    private var fileMatches: [QuickOpenEntry] {
        guard !isCommandMode, !isSymbolMode else { return [] }
        return matchCache.matches(
            query: query,
            index: appState.quickOpenIndex,
            version: appState.quickOpenIndexVersion
        )
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
                                        // Identity must match the ForEach's
                                        // own `id:`. An `.id(i)` here
                                        // overrode it with the row's index,
                                        // and a LazyVStack then reused the
                                        // already-realized rows and never
                                        // refreshed their content — the list
                                        // stayed on the previous query.
                                        .id(binding.id)
                                        .onTapGesture { invoke(binding.action) }
                                    }
                                }
                            }
                            .frame(maxHeight: 360)
                            .onChange(of: selectedIndex) { _, idx in
                                guard matches.indices.contains(idx) else { return }
                                proxy.scrollTo(matches[idx].id, anchor: .center)
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
                                        .id(entry.symbol.id)
                                        .onTapGesture { selectSymbol(entry.symbol) }
                                    }
                                }
                            }
                            .frame(maxHeight: 360)
                            .onChange(of: selectedIndex) { _, idx in
                                guard matches.indices.contains(idx) else { return }
                                proxy.scrollTo(matches[idx].symbol.id, anchor: .center)
                            }
                        }
                    }
                } else {
                    let matches = fileMatches
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
                                    Array(matches.enumerated()),
                                    id: \.element.id
                                ) { i, entry in
                                    QuickOpenRow(
                                        name: entry.name,
                                        relativeDirectory: entry.relativeDirectory,
                                        isSelected: i == selectedIndex
                                    )
                                    .id(entry.id)
                                    .onTapGesture { open(entry) }
                                }
                            }
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: selectedIndex) { _, idx in
                            guard matches.indices.contains(idx) else { return }
                            proxy.scrollTo(matches[idx].id, anchor: .center)
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
        return fileMatches.count
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
            guard selectedIndex < fileMatches.count else { return }
            open(fileMatches[selectedIndex])
        }
    }

    private func open(_ entry: QuickOpenEntry) {
        Task { await appState.openFile(entry.file.url) }
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
    let name: String
    /// Workspace-relative directory, precomputed by `QuickOpenEntry`.
    let relativeDirectory: String?
    let isSelected: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: appState.sf(13)))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                if let rel = relativeDirectory {
                    Text(rel)
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(isSelected ? .white.opacity(0.65) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
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
