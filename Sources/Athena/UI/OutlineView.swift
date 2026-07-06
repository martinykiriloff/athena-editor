// OutlineView.swift
// Athena — sidebar panel: hierarchical list of the active file's document symbols.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - OutlineView

/// Flat, depth-indented rendering of `AppState.documentSymbols` (the same
/// tree Go to Symbol (⇧⌘O) and the breadcrumbs bar read from), so this panel
/// never issues its own LSP request. Clicking a row jumps to that symbol via
/// `AppState.navigateTo`, the same cross-view jump mechanism every other
/// symbol/reference navigation in the app uses.
struct OutlineView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if appState.focusedTab?.fileURL == nil {
                emptyState("No file open")
            } else if flattened.isEmpty {
                emptyState("No symbols")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(flattened, id: \.symbol.id) { entry in
                            OutlineSymbolRow(symbol: entry.symbol, depth: entry.depth) {
                                jump(to: entry.symbol)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var flattened: [(symbol: DocumentSymbol, depth: Int)] {
        flattenDocumentSymbols(appState.documentSymbols)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: appState.sf(12)))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func jump(to symbol: DocumentSymbol) {
        guard let fileURL = appState.focusedTab?.fileURL else { return }
        Task {
            await appState.navigateTo(
                DefinitionLocation(fileURL: fileURL, line: symbol.line, character: symbol.character)
            )
        }
    }
}

// MARK: - OutlineSymbolRow

private struct OutlineSymbolRow: View {
    let symbol: DocumentSymbol
    let depth: Int
    let onTap: () -> Void
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

            Image(systemName: symbol.iconName)
                .font(.system(size: appState.sf(11)))
                .foregroundColor(.secondary)
                .frame(width: 14)

            Text(symbol.name)
                .font(.system(size: appState.sf(12)))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
