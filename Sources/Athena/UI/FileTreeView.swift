// FileTreeView.swift
// Athena — workspace file tree sidebar panel.
// Swift 6, strict concurrency.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - FileTreeView

struct FileTreeView: View {
    @Environment(AppState.self) private var appState

    @State private var nodeToDelete: FileNode?
    @State private var showDeleteConfirmation: Bool = false
    @State private var nodeToRename: FileNode?
    @State private var renameText: String = ""
    @State private var showRenameSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            fileList
        }
        .onAppear {
            Task {
                if let ws = appState.workspace {
                    let tree = try? await appState.fileService.buildFileTree(ws.rootURL)
                    appState.fileTree = tree ?? []
                }
            }
        }
        .alert("Delete \"\(nodeToDelete?.name ?? "")\"?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let node = nodeToDelete {
                    Task {
                        try? await appState.fileService.delete(node.url)
                        if let ws = appState.workspace {
                            let tree = try? await appState.fileService.buildFileTree(ws.rootURL)
                            appState.fileTree = tree ?? []
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSheet(
                originalName: nodeToRename?.name ?? "",
                renameText: $renameText
            ) { newName in
                if let node = nodeToRename, !newName.isEmpty {
                    Task {
                        _ = try? await appState.fileService.rename(node.url, to: newName)
                        if let ws = appState.workspace {
                            let tree = try? await appState.fileService.buildFileTree(ws.rootURL)
                            appState.fileTree = tree ?? []
                        }
                    }
                }
            }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 4) {
            Text(appState.workspace?.name ?? "No Workspace")
                .font(.system(size: appState.sf(11), weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // New file
            headerButton(systemImage: "doc.badge.plus", tooltip: "New File") {
                if let ws = appState.workspace {
                    let newURL = ws.rootURL.appendingPathComponent("untitled")
                    Task {
                        try? await appState.fileService.createFile(at: newURL)
                        let tree = try? await appState.fileService.buildFileTree(ws.rootURL)
                        appState.fileTree = tree ?? []
                    }
                }
            }

            // New folder
            headerButton(systemImage: "folder.badge.plus", tooltip: "New Folder") {
                if let ws = appState.workspace {
                    let newURL = ws.rootURL.appendingPathComponent("untitled-folder")
                    Task {
                        try? await appState.fileService.createDirectory(at: newURL)
                        let tree = try? await appState.fileService.buildFileTree(ws.rootURL)
                        appState.fileTree = tree ?? []
                    }
                }
            }

            // Collapse all
            headerButton(systemImage: "arrow.up.to.line", tooltip: "Collapse All") {
                collapseAll(&appState.fileTree)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 32)
    }

    @ViewBuilder
    private func headerButton(
        systemImage: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: appState.sf(12)))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: File List

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(flattenTree(appState.fileTree)) { node in
                    FileNodeRow(node: node) {
                        handleTap(node)
                    } onNewFile: {
                        handleNewFile(in: node)
                    } onNewFolder: {
                        handleNewFolder(in: node)
                    } onRename: {
                        nodeToRename = node
                        renameText = node.name
                        showRenameSheet = true
                    } onDelete: {
                        nodeToDelete = node
                        showDeleteConfirmation = true
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func flattenTree(_ nodes: [FileNode]) -> [FileNode] {
        var result: [FileNode] = []
        for node in nodes {
            result.append(node)
            if node.isDirectory && node.isExpanded, let children = node.children {
                result.append(contentsOf: flattenTree(children))
            }
        }
        return result
    }

    private func collapseAll(_ nodes: inout [FileNode]) {
        for i in nodes.indices {
            nodes[i].isExpanded = false
            if nodes[i].children != nil {
                collapseAll(&nodes[i].children!)
            }
        }
    }

    private func handleTap(_ node: FileNode) {
        if node.isDirectory {
            toggleExpanded(node, in: &appState.fileTree)
            if isExpanded(node, in: appState.fileTree) {
                Task {
                    let children = try? await appState.fileService.buildFileTree(node.url)
                    updateChildren(for: node, with: children ?? [], in: &appState.fileTree)
                }
            }
        } else {
            Task {
                await appState.openFile(node.url)
            }
        }
    }

    private func handleNewFile(in node: FileNode) {
        let dir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent("untitled")
        Task {
            try? await appState.fileService.createFile(at: newURL)
            if let ws = appState.workspace {
                let tree = try? await appState.fileService.buildFileTree(ws.rootURL)
                appState.fileTree = tree ?? []
            }
        }
    }

    private func handleNewFolder(in node: FileNode) {
        let dir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent("untitled-folder")
        Task {
            try? await appState.fileService.createDirectory(at: newURL)
            if let ws = appState.workspace {
                let tree = try? await appState.fileService.buildFileTree(ws.rootURL)
                appState.fileTree = tree ?? []
            }
        }
    }

    // MARK: Tree mutation helpers

    private func toggleExpanded(_ target: FileNode, in nodes: inout [FileNode]) {
        for i in nodes.indices {
            if nodes[i].id == target.id {
                nodes[i].isExpanded.toggle()
                return
            }
            if nodes[i].children != nil {
                toggleExpanded(target, in: &nodes[i].children!)
            }
        }
    }

    private func isExpanded(_ target: FileNode, in nodes: [FileNode]) -> Bool {
        for node in nodes {
            if node.id == target.id { return node.isExpanded }
            if let children = node.children {
                let found = isExpanded(target, in: children)
                if found { return true }
            }
        }
        return false
    }

    private func updateChildren(
        for target: FileNode,
        with children: [FileNode],
        in nodes: inout [FileNode]
    ) {
        for i in nodes.indices {
            if nodes[i].id == target.id {
                // Assign depth to children
                var depthChildren = children
                setDepth(&depthChildren, depth: target.depth + 1)
                nodes[i].children = depthChildren
                return
            }
            if nodes[i].children != nil {
                updateChildren(for: target, with: children, in: &nodes[i].children!)
            }
        }
    }

    private func setDepth(_ nodes: inout [FileNode], depth: Int) {
        for i in nodes.indices {
            nodes[i] = FileNode(
                url: nodes[i].url,
                isDirectory: nodes[i].isDirectory,
                children: nodes[i].children,
                isExpanded: nodes[i].isExpanded,
                depth: depth
            )
        }
    }
}

// MARK: - FileNodeRow

private struct FileNodeRow: View {
    let node: FileNode
    let onTap: () -> Void
    let onNewFile: () -> Void
    let onNewFolder: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @Environment(AppState.self) private var appState

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            // Indentation
            Color.clear
                .frame(width: CGFloat(node.depth) * 14, height: 1)

            // Chevron (directories only)
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: appState.sf(10), weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(node.isExpanded ? .degrees(90) : .degrees(0))
                    .animation(.easeInOut(duration: 0.15), value: node.isExpanded)
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14)
            }

            // File/folder icon
            fileIcon
                .font(.system(size: appState.sf(13)))
                .frame(width: 16)

            // Filename
            Text(node.name)
                .font(.system(size: appState.sf(13)))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onTap() }
        .contextMenu {
            Button("New File Here") { onNewFile() }
            Button("New Folder Here") { onNewFolder() }
            Divider()
            Button("Rename") { onRename() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    @ViewBuilder
    private var fileIcon: some View {
        if node.isDirectory {
            Image(systemName: "folder.fill")
                .foregroundColor(.orange)
        } else {
            let lang = Language.detect(from: node.url)
            Image(systemName: iconName(for: lang))
                .foregroundColor(iconColor(for: lang))
        }
    }

    private func iconName(for language: Language) -> String {
        switch language {
        case .swift, .typescript, .javascript, .python, .rust, .go, .json, .css, .html, .ds:
            return "doc.text.fill"
        case .isml:
            return "curlybraces.square.fill"
        case .markdown:
            return "doc.richtext.fill"
        case .plaintext:
            return "doc.text"
        }
    }

    private func iconColor(for language: Language) -> Color {
        switch language {
        case .swift:      return .orange
        case .typescript: return .blue
        case .javascript: return .yellow
        case .python:     return .green
        case .rust:       return Color(red: 0.9, green: 0.4, blue: 0.2)
        case .go:         return .cyan
        case .json:       return .gray
        case .css:        return .purple
        case .html:       return .orange
        case .isml:       return Color(red: 0.0, green: 0.68, blue: 0.94)
        case .ds:         return Color(red: 0.0, green: 0.68, blue: 0.94)
        case .markdown:   return .white
        case .plaintext:  return .secondary
        }
    }
}

// MARK: - RenameSheet

private struct RenameSheet: View {
    let originalName: String
    @Binding var renameText: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename \"\(originalName)\"")
                .font(.headline)

            TextField("New name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commit() {
        onConfirm(renameText)
        dismiss()
    }
}
