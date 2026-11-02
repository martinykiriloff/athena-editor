// HierarchyPanelView.swift
// Athena — bottom panel showing an LSP call or type hierarchy as an expandable tree.
// Swift 6, strict concurrency.

import SwiftUI

struct HierarchyPanelView: View {
    @Environment(AppState.self) private var appState

    private var directions: [HierarchyDirection] {
        appState.hierarchyDirection.isCall ? [.incomingCalls, .outgoingCalls] : [.supertypes, .subtypes]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: appState.sf(8)) {
                Picker("", selection: Binding(
                    get: { appState.hierarchyDirection },
                    set: { d in Task { await appState.setHierarchyDirection(d) } }
                )) {
                    ForEach(directions, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: appState.sf(220))
                if appState.isLoadingHierarchy { ProgressView().scaleEffect(0.6) }
                Spacer()
            }
            .padding(.horizontal, appState.sf(10))
            .frame(height: appState.sf(28))
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()

            if appState.hierarchyRoots.isEmpty && !appState.isLoadingHierarchy {
                Text("Place the caret on a symbol and run Show Call Hierarchy (⇧⌥H)")
                    .font(.system(size: appState.sf(12)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(appState.hierarchyRoots) { root in
                            HierarchyNodeView(item: root, depth: 0)
                        }
                    }
                    .padding(.vertical, appState.sf(4))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HierarchyNodeView: View {
    @Environment(AppState.self) private var appState
    let item: HierarchyItem
    let depth: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: appState.sf(4)) {
                Button {
                    expanded.toggle()
                    if expanded { Task { await appState.loadChildren(of: item) } }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: appState.sf(9)))
                        .frame(width: appState.sf(14))
                }
                .buttonStyle(.plain)
                Text(item.name).font(.system(size: appState.sf(12), weight: .medium))
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: appState.sf(11))).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(item.fileURL.lastPathComponent):\(item.line + 1)")
                    .font(.system(size: appState.sf(11))).foregroundStyle(.secondary)
                if item.callSiteCount > 1 {
                    Text("×\(item.callSiteCount)").font(.system(size: appState.sf(11))).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, appState.sf(CGFloat(8 + depth * 14)))
            .padding(.trailing, appState.sf(10))
            .frame(height: appState.sf(22))
            .contentShape(Rectangle())
            .onTapGesture { Task { await appState.openHierarchyItem(item) } }

            if expanded {
                ForEach(appState.hierarchyChildren[item.id] ?? []) { child in
                    HierarchyNodeView(item: child, depth: depth + 1)
                }
            }
        }
    }
}
