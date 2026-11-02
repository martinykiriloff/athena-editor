// FrameworkPaletteView.swift
// Athena — fuzzy list palette for framework routes and workspace packages.
// Swift 6, strict concurrency.

import SwiftUI

struct FrameworkPaletteView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var palette: FrameworkPalette? { appState.frameworkPalette }

    private var matches: [FrameworkPaletteItem] {
        guard let items = palette?.items else { return [] }
        guard !query.isEmpty else { return Array(items.prefix(300)) }
        return items
            .compactMap { item -> (FrameworkPaletteItem, Int)? in
                let score = [fuzzyNameScore(query: query, target: item.title),
                             fuzzyNameScore(query: query, target: item.subtitle).map { $0 / 2 }]
                    .compactMap { $0 }.max()
                return score.map { (item, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .prefix(300)
            .map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: appState.sf(8)) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(.secondary)
                        .font(.system(size: appState.sf(14)))
                    TextField(palette?.title ?? "", text: $query)
                        .font(.system(size: appState.sf(16)))
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onKeyPress(.upArrow)   { move(-1); return .handled }
                        .onKeyPress(.downArrow) { move(1);  return .handled }
                        .onKeyPress(.return)    { confirm(); return .handled }
                        .onKeyPress(.escape)    { close();   return .handled }
                }
                .padding(.horizontal, appState.sf(12))
                .padding(.vertical, appState.sf(10))

                let list = matches
                Divider()
                if list.isEmpty {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                        .font(.system(size: appState.sf(12)))
                        .padding(appState.sf(20))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                                    FrameworkPaletteRow(item: item, isSelected: i == selectedIndex)
                                        .id(item.id)
                                        .onTapGesture { choose(item) }
                                }
                            }
                        }
                        .frame(maxHeight: appState.sf(360))
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
            .frame(width: appState.sf(580))
            .padding(.top, appState.sf(80))
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { selectedIndex = 0 }
    }

    private func move(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func confirm() {
        let list = matches
        guard list.indices.contains(selectedIndex) else { return }
        choose(list[selectedIndex])
    }

    private func choose(_ item: FrameworkPaletteItem) {
        Task { await appState.selectFrameworkPaletteItem(item) }
    }

    private func close() { appState.frameworkPalette = nil }
}

private struct FrameworkPaletteRow: View {
    let item: FrameworkPaletteItem
    let isSelected: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: appState.sf(8)) {
            Image(systemName: item.icon)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: appState.sf(16))
            VStack(alignment: .leading, spacing: appState.sf(1)) {
                Text(item.title)
                    .font(.system(size: appState.sf(13)))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(isSelected ? .white.opacity(0.65) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(item.badge)
                .font(.system(size: appState.sf(11), weight: .medium))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
        }
        .padding(.horizontal, appState.sf(12))
        .padding(.vertical, appState.sf(6))
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}
