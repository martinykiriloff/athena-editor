// WorkspaceSymbolView.swift
// Athena — ⌘T "Go to Symbol in Workspace" palette backed by LSP workspace/symbol.
// Swift 6, strict concurrency.

import SwiftUI

struct WorkspaceSymbolView: View {
    @Environment(AppState.self) private var appState

    @State private var query = ""
    @State private var results: [WorkspaceSymbol] = []
    @State private var selectedIndex = 0
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private static let maxResults = 200

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
                    TextField("Go to symbol in workspace", text: $query)
                        .font(.system(size: appState.sf(16)))
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onKeyPress(.upArrow)   { move(-1); return .handled }
                        .onKeyPress(.downArrow) { move(1);  return .handled }
                        .onKeyPress(.return)    { confirmSelection(); return .handled }
                        .onKeyPress(.escape)    { close(); return .handled }
                    if isSearching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, appState.sf(12))
                .padding(.vertical, appState.sf(10))

                if results.isEmpty {
                    if hasSearched && !isSearching {
                        Divider()
                        Text(query.isEmpty ? "Type to search symbols (needs a running language server)" : "No matching symbols")
                            .foregroundStyle(.secondary)
                            .font(.system(size: appState.sf(12)))
                            .padding(appState.sf(20))
                    }
                } else {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { i, symbol in
                                    WorkspaceSymbolRow(symbol: symbol, isSelected: i == selectedIndex)
                                        .id(symbol.id)
                                        .onTapGesture { select(symbol) }
                                }
                            }
                        }
                        .frame(maxHeight: appState.sf(360))
                        .onChange(of: selectedIndex) { _, idx in
                            guard results.indices.contains(idx) else { return }
                            proxy.scrollTo(results[idx].id, anchor: .center)
                        }
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: appState.sf(10)))
            .shadow(color: .black.opacity(0.5), radius: appState.sf(24), x: 0, y: appState.sf(12))
            .frame(width: appState.sf(580))
            .padding(.top, appState.sf(80))
        }
        .onAppear {
            searchFocused = true
            scheduleSearch(delay: .zero)
        }
        .onChange(of: query) { scheduleSearch(delay: .milliseconds(150)) }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Search

    /// Debounced; each new keystroke cancels the previous task, and a reply
    /// only lands if its task wasn't cancelled meanwhile (a stale slow reply
    /// must not replace newer results).
    private func scheduleSearch(delay: Duration) {
        searchTask?.cancel()
        let text = query
        let manager = appState.lspManager
        isSearching = true
        searchTask = Task {
            if delay > .zero {
                let clock = ContinuousClock()
                try? await clock.sleep(until: clock.now.advanced(by: delay))
            }
            guard !Task.isCancelled else { return }
            let found = await manager.workspaceSymbols(query: text)
            guard !Task.isCancelled else { return }
            results = Array(found.prefix(Self.maxResults))
            selectedIndex = 0
            hasSearched = true
            isSearching = false
        }
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    private func confirmSelection() {
        guard results.indices.contains(selectedIndex) else { return }
        select(results[selectedIndex])
    }

    private func select(_ symbol: WorkspaceSymbol) {
        Task { await appState.navigateTo(symbol.location) }
        close()
    }

    private func close() {
        searchTask?.cancel()
        appState.showWorkspaceSymbols = false
    }
}

// MARK: - Row

private struct WorkspaceSymbolRow: View {
    let symbol: WorkspaceSymbol
    let isSelected: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: appState.sf(8)) {
            Image(systemName: symbol.iconName)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: appState.sf(14))
            Text(symbol.name)
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
            if let container = symbol.containerName {
                Text(container)
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(symbol.fileURL.lastPathComponent)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, appState.sf(12))
        .padding(.vertical, appState.sf(6))
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}
