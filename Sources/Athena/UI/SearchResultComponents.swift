// SearchResultComponents.swift
// Athena — file-grouped SearchResult rendering shared by SearchPanelView and ReferencesPanelView.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - SearchFileGroup

/// One file's worth of `SearchResult` rows. Shared by `SearchPanelView`
/// (workspace search/replace) and `ReferencesPanelView` ("Find All
/// References") so both file-grouped result lists use identical grouping
/// and rendering rather than two near-duplicate implementations.
struct SearchFileGroup: Identifiable {
    var id: String { filePath }
    let filePath: String
    let results: [SearchResult]

    /// Groups a flat `SearchResult` list by file, preserving first-seen file
    /// order (the order results originally streamed in).
    static func grouping(_ results: [SearchResult]) -> [SearchFileGroup] {
        var order: [String] = []
        var map: [String: [SearchResult]] = [:]
        for result in results {
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
}

// MARK: - SearchFileGroupView

struct SearchFileGroupView: View {
    let group: SearchFileGroup
    let workspaceRoot: URL?
    let onSelect: (SearchResult) -> Void
    @Environment(AppState.self) private var appState

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
                        .font(.system(size: appState.sf(10), weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text(fileName)
                        .font(.system(size: appState.sf(12), weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(relativePath)
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    // Match count badge
                    Text("\(group.results.count)")
                        .font(.system(size: appState.sf(10), weight: .medium))
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

struct SearchResultRowView: View {
    let result: SearchResult
    let onSelect: () -> Void
    @Environment(AppState.self) private var appState

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 0) {
                // Line number column
                Text("\(result.lineNumber)")
                    .font(.system(size: appState.sf(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .padding(.trailing, 8)

                // Line content
                Text(result.lineContent.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: appState.sf(12), design: .monospaced))
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
