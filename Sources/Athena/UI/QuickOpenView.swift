// QuickOpenView.swift
// Athena — ⌘P file-search palette (VS Code parity).
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

// MARK: - QuickOpenView

struct QuickOpenView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool

    // MARK: - Filtered results

    private var results: [FileNode] {
        let all = appState.allFiles
        guard !query.isEmpty else { return Array(all.prefix(200)) }
        let q = query.lowercased()
        return all
            .filter { $0.url.path.lowercased().contains(q) }
            .sorted { a, b in
                let aPrefix = a.name.lowercased().hasPrefix(q)
                let bPrefix = b.name.lowercased().hasPrefix(q)
                if aPrefix != bPrefix { return aPrefix }
                let aName = a.name.lowercased().contains(q)
                let bName = b.name.lowercased().contains(q)
                if aName != bName { return aName }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
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

                    TextField("Go to file…", text: $query)
                        .font(.system(size: appState.sf(16)))
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        // Arrow keys — navigate the list
                        .onKeyPress(.upArrow)   { move(-1); return .handled }
                        .onKeyPress(.downArrow) { move(1);  return .handled }
                        // Return — open the selected file
                        .onKeyPress(.return)    { confirmSelection(); return .handled }
                        // Escape — dismiss
                        .onKeyPress(.escape)    { close(); return .handled }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                // Results or empty state
                if results.isEmpty && !query.isEmpty {
                    Divider()
                    Text("No results for \"\(query)\"")
                        .foregroundStyle(.secondary)
                        .font(.system(size: appState.sf(12)))
                        .padding(20)
                } else if !results.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(
                                    Array(results.prefix(200).enumerated()),
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
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
            .frame(width: 580)
            .padding(.top, 80)
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { selectedIndex = 0 }
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let count = min(results.count, 200)
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func confirmSelection() {
        guard selectedIndex < results.count else { return }
        open(results[selectedIndex])
    }

    private func open(_ file: FileNode) {
        Task { await appState.openFile(file.url) }
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
