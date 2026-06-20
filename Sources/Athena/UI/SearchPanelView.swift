// SearchPanelView.swift
// Athena — sidebar search panel backed by SearchService (grep / ripgrep).
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - SearchPanelView

struct SearchPanelView: View {
    @Environment(AppState.self) private var appState

    @State private var useRegex:       Bool   = false
    @State private var caseSensitive:  Bool   = false
    @State private var isSearching:    Bool   = false
    @State private var showFilters:    Bool   = false
    @State private var includePattern: String = ""
    @State private var excludePattern: String = ""
    @State private var debounceTask:   Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if showFilters { filterSection }
            statusLine
            Divider()
            resultsArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            @Bindable var state = appState
            TextField("Search", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { triggerSearch() }
                .onChange(of: appState.searchQuery) { _, _ in scheduleDebounce() }

            toggleButton(symbol: ".*", help: "Use Regular Expression", isOn: $useRegex)
            toggleButton(symbol: "Aa", help: "Match Case",             isOn: $caseSensitive)

            // Filter toggle
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showFilters.toggle() }
            } label: {
                Image(systemName: showFilters
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(showFilters ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle filters")

            if !appState.searchQuery.isEmpty {
                Button {
                    appState.searchQuery  = ""
                    appState.searchResults = []
                    debounceTask?.cancel()
                    Task { await appState.searchService.cancel() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Filter Section

    private var filterSection: some View {
        VStack(spacing: 0) {
            filterRow(
                label: "Include",
                placeholder: "e.g. *.swift, src",
                text: $includePattern
            )
            Divider().padding(.leading, 8)
            filterRow(
                label: "Exclude",
                placeholder: "e.g. node_modules, .build, *.lock",
                text: $excludePattern
            )
            Divider()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func filterRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { triggerSearch() }
                .onChange(of: text.wrappedValue) { _, _ in scheduleDebounce() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Toggle Button Helper

    private func toggleButton(
        symbol: String,
        help: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            if !appState.searchQuery.isEmpty { triggerSearch() }
        } label: {
            Text(symbol)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue
                              ? Color.accentColor.opacity(0.15)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Status Line

    @ViewBuilder
    private var statusLine: some View {
        HStack {
            if isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
                Text("Searching…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if !appState.searchQuery.isEmpty {
                let fileCount = fileGroups.count
                let matchCount = appState.searchResults.count
                Text(
                    matchCount == 0
                        ? "No results"
                        : "\(matchCount) result\(matchCount == 1 ? "" : "s") in \(fileCount) file\(fileCount == 1 ? "" : "s")"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Results Area

    @ViewBuilder
    private var resultsArea: some View {
        if appState.searchQuery.isEmpty {
            emptyPrompt(
                icon: "magnifyingglass",
                message: "Type to search across workspace files"
            )
        } else if !isSearching && appState.searchResults.isEmpty {
            emptyPrompt(
                icon: "doc.text.magnifyingglass",
                message: "No results for \"\(appState.searchQuery)\""
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(fileGroups, id: \.filePath) { group in
                        SearchFileGroupView(
                            group: group,
                            workspaceRoot: appState.workspace?.rootURL
                        ) { result in
                            Task {
                                await appState.openFile(URL(fileURLWithPath: result.filePath))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Computed Groups

    private var fileGroups: [SearchFileGroup] {
        var order: [String] = []
        var map: [String: [SearchResult]] = [:]
        for result in appState.searchResults {
            if map[result.filePath] == nil {
                order.append(result.filePath)
                map[result.filePath] = []
            }
            map[result.filePath]!.append(result)
        }
        return order.compactMap { path in
            guard let results = map[path] else { return nil }
            return SearchFileGroup(filePath: path, results: results)
        }
    }

    // MARK: - Helpers

    private func emptyPrompt(icon: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            triggerSearch()
        }
    }

    private func triggerSearch() {
        let query = appState.searchQuery
        guard !query.isEmpty, let ws = appState.workspace else {
            appState.searchResults = []
            isSearching = false
            return
        }
        let root    = ws.rootURL
        let regex   = useRegex
        let cs      = caseSensitive
        let filter  = SearchFilter(include: includePattern, exclude: excludePattern)

        Task {
            isSearching = true
            appState.searchResults = []
            await appState.searchService.cancel()
            let stream = await appState.searchService.search(
                query:         query,
                in:            root,
                regex:         regex,
                caseSensitive: cs,
                filter:        filter
            )
            for await result in stream {
                appState.searchResults.append(result)
            }
            isSearching = false
        }
    }
}

// MARK: - SearchFileGroup

private struct SearchFileGroup: Identifiable {
    var id: String { filePath }
    let filePath: String
    let results: [SearchResult]
}

// MARK: - SearchFileGroupView

private struct SearchFileGroupView: View {
    let group: SearchFileGroup
    let workspaceRoot: URL?
    let onSelect: (SearchResult) -> Void

    @State private var isExpanded: Bool = true

    private var fileName: String {
        URL(fileURLWithPath: group.filePath).lastPathComponent
    }

    private var relativePath: String {
        if let root = workspaceRoot {
            let rootPath = root.path
            var rel = group.filePath
            if rel.hasPrefix(rootPath) {
                rel = String(rel.dropFirst(rootPath.count))
                if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            }
            return rel
        }
        return group.filePath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text(fileName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(relativePath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    // Match count badge
                    Text("\(group.results.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.8))
                        )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            }
            .buttonStyle(.plain)

            // Result rows
            if isExpanded {
                ForEach(group.results) { result in
                    SearchResultRowView(result: result) {
                        onSelect(result)
                    }
                }
            }
        }
    }
}

// MARK: - SearchResultRowView

private struct SearchResultRowView: View {
    let result: SearchResult
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 0) {
                // Line number column
                Text("\(result.lineNumber)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .padding(.trailing, 8)

                // Line content
                Text(result.lineContent.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered
                        ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3)
                        : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
