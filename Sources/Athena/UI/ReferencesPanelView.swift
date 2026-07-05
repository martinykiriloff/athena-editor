// ReferencesPanelView.swift
// Athena — bottom panel showing "Find All References" (⌥⇧F12) results.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - ReferencesPanelView

/// Reuses `SearchFileGroup`/`SearchFileGroupView` (`SearchResultComponents.swift`) —
/// the exact same file-grouped row rendering used for workspace search
/// results — backed by `AppState.referencesResults` instead of
/// `appState.searchResults` so a "Find All References" lookup never
/// clobbers an in-progress workspace search. Selecting a row jumps the
/// editor to that location via `AppState.navigateToReference(_:)`.
struct ReferencesPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            resultsArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status Line

    private var statusLine: some View {
        HStack {
            if appState.isFindingReferences {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
                Text("Finding references…")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
            } else {
                let count = appState.referencesResults.count
                Text(
                    appState.referencesSymbol.isEmpty
                        ? "\(count) reference\(count == 1 ? "" : "s")"
                        : "\(count) reference\(count == 1 ? "" : "s") to \"\(appState.referencesSymbol)\""
                )
                .font(.system(size: appState.sf(11)))
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
        if !appState.isFindingReferences && appState.referencesResults.isEmpty {
            emptyPrompt
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(fileGroups, id: \.filePath) { group in
                        SearchFileGroupView(
                            group: group,
                            workspaceRoot: appState.workspace?.rootURL
                        ) { result in
                            Task { await appState.navigateToReference(result) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: appState.sf(28)))
                .foregroundStyle(.secondary)
            Text("No references found")
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Computed Groups

    /// Grouping logic itself lives on `SearchFileGroup` (`SearchResultComponents.swift`),
    /// shared with `SearchPanelView`.
    private var fileGroups: [SearchFileGroup] {
        SearchFileGroup.grouping(appState.referencesResults)
    }
}
