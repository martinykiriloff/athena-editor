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
    @State private var nameEntry: NameEntry?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            fileList
        }
        .onAppear {
            Task { await appState.refreshFileTree() }
        }
        .alert("Delete \"\(nodeToDelete?.name ?? "")\"?", isPresented: $showDeleteConfirmation) {
            Button("Move to Trash", role: .destructive) {
                if let node = nodeToDelete {
                    Task { await appState.trashExplorerItem(node.url) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(nodeToDelete?.isDirectory == true
                 ? "The folder and its contents will be moved to the Trash."
                 : "The file will be moved to the Trash.")
        }
        .sheet(item: $nameEntry) { entry in
            NameEntrySheet(entry: entry) { name in
                Task { await commit(entry, name: name) }
            }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: appState.sf(4)) {
            Text(appState.workspace?.name ?? "No Workspace")
                .font(.system(size: appState.sf(11), weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            headerButton(systemImage: "doc.badge.plus", tooltip: "New File…") {
                if let root = appState.workspace?.rootURL { nameEntry = .newFile(in: root) }
            }

            headerButton(systemImage: "folder.badge.plus", tooltip: "New Folder…") {
                if let root = appState.workspace?.rootURL { nameEntry = .newFolder(in: root) }
            }

            headerButton(systemImage: "arrow.clockwise", tooltip: "Refresh Explorer") {
                Task { await appState.refreshFileTree() }
            }

            headerButton(systemImage: "arrow.up.to.line", tooltip: "Collapse All") {
                collapseAll(&appState.fileTree)
            }
        }
        .padding(.horizontal, appState.sf(8))
        .padding(.vertical, appState.sf(6))
        .frame(height: appState.sf(32))
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
                    } menu: {
                        FileNodeContextMenu(node: node) { action in
                            handle(action, for: node)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // Right-clicking empty space below the rows targets the workspace
        // root (rows install their own, more specific menu).
        .contentShape(Rectangle())
        .contextMenu {
            if let root = appState.workspace?.rootURL {
                let rootNode = FileNode(url: root, isDirectory: true, depth: -1)
                FileNodeContextMenu(node: rootNode, isWorkspaceRoot: true) { action in
                    handle(action, for: rootNode)
                }
            }
        }
    }

    // MARK: - Actions

    private func handle(_ action: FileNodeAction, for node: FileNode) {
        let url = node.url
        let folder = node.isDirectory ? url : url.deletingLastPathComponent()
        switch action {
        case .newFile:             nameEntry = .newFile(in: folder)
        case .newFolder:           nameEntry = .newFolder(in: folder)
        case .open:                handleTap(node)
        case .openToSide:          Task { await appState.openFileToSide(url) }
        case .openWithDefaultApp:  appState.openWithDefaultApp(url)
        case .revealInFinder:      appState.revealInFinder(url)
        case .openInTerminal:      appState.openInIntegratedTerminal(url, isDirectory: node.isDirectory)
        case .findInFolder:        appState.findInFolder(url)
        case .selectForCompare:    appState.selectForCompare(url)
        case .compareWithSelected: Task { await appState.compareWithSelected(url) }
        case .openChanges:         Task { await appState.openChanges(for: url) }
        case .fileHistory:         Task { await appState.showExplorerFileHistory(url) }
        case .addToClaudeChat:     appState.addExplorerItemToClaudeChat(url, isDirectory: node.isDirectory)
        case .cut:                 appState.cutExplorerItems([url])
        case .copy:                appState.copyExplorerItems([url])
        case .paste:               Task { await appState.pasteExplorerItems(into: folder) }
        case .duplicate:           Task { await appState.duplicateExplorerItem(url) }
        case .copyPath:            appState.copyPathToPasteboard(url)
        case .copyRelativePath:    appState.copyRelativePathToPasteboard(url)
        case .rename:              nameEntry = .rename(url)
        case .delete:
            nodeToDelete = node
            showDeleteConfirmation = true
        }
    }

    private func commit(_ entry: NameEntry, name: String) async {
        switch entry {
        case .newFile(let dir):   await appState.createExplorerFile(named: name, in: dir)
        case .newFolder(let dir): await appState.createExplorerFolder(named: name, in: dir)
        case .rename(let url):    await appState.renameExplorerItem(url, to: name)
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
                    // Re-list at the right depth so nested rows indent
                    // correctly, keeping any expanded subfolders open.
                    let previous = AppState.expandedPaths(in: node.children ?? [])
                    var children = (try? await appState.fileService.buildFileTree(node.url, depth: node.depth + 1)) ?? []
                    AppState.applyExpansion(previous, to: &children)
                    updateChildren(for: node, with: children, in: &appState.fileTree)
                }
            }
        } else {
            Task {
                await appState.openFile(node.url)
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
                nodes[i].children = children
                return
            }
            if nodes[i].children != nil {
                updateChildren(for: target, with: children, in: &nodes[i].children!)
            }
        }
    }
}

// MARK: - FileNodeAction

/// Everything the explorer context menu can do to a node.
private enum FileNodeAction {
    case newFile, newFolder
    case open, openToSide, openWithDefaultApp, revealInFinder, openInTerminal
    case findInFolder
    case selectForCompare, compareWithSelected
    case openChanges, fileHistory
    case addToClaudeChat
    case cut, copy, paste, duplicate
    case copyPath, copyRelativePath
    case rename, delete
}

// MARK: - FileNodeContextMenu

/// VS Code explorer-style menu. Folders get create/find-in-folder actions,
/// files get open/compare/git actions; the workspace root (empty-space
/// right-click) omits the rename/delete/clipboard-source items.
private struct FileNodeContextMenu: View {
    let node: FileNode
    var isWorkspaceRoot: Bool = false
    let perform: (FileNodeAction) -> Void
    @Environment(AppState.self) private var appState

    var body: some View {
        if node.isDirectory {
            Button("New File…") { perform(.newFile) }
            Button("New Folder…") { perform(.newFolder) }
            Divider()
            Button("Reveal in Finder") { perform(.revealInFinder) }
            Button("Open in Integrated Terminal") { perform(.openInTerminal) }
            Divider()
            Button("Find in Folder…") { perform(.findInFolder) }
            if !isWorkspaceRoot {
                Button("Open Folder History") { perform(.fileHistory) }
            }
            Divider()
            Button("Add Folder to Claude Chat") { perform(.addToClaudeChat) }
        } else {
            Button("Open") { perform(.open) }
            Button("Open to the Side") { perform(.openToSide) }
            Button("Open with Default App") { perform(.openWithDefaultApp) }
            Button("Reveal in Finder") { perform(.revealInFinder) }
            Button("Open in Integrated Terminal") { perform(.openInTerminal) }
            Divider()
            Button("Select for Compare") { perform(.selectForCompare) }
            if let selected = appState.compareSelectionURL, selected != node.url {
                Button("Compare with \(selected.lastPathComponent)") { perform(.compareWithSelected) }
            }
            Divider()
            if appState.gitChange(for: node.url) != nil {
                Button("Open Changes") { perform(.openChanges) }
            }
            Button("Open File History") { perform(.fileHistory) }
            Divider()
            Button("Add File to Claude Chat") { perform(.addToClaudeChat) }
        }

        Divider()
        if !isWorkspaceRoot {
            Button("Cut") { perform(.cut) }
            Button("Copy") { perform(.copy) }
        }
        Button("Paste") { perform(.paste) }
        if !isWorkspaceRoot {
            Button("Duplicate") { perform(.duplicate) }
        }

        Divider()
        Button("Copy Path") { perform(.copyPath) }
        if !isWorkspaceRoot {
            Button("Copy Relative Path") { perform(.copyRelativePath) }
        }

        if !isWorkspaceRoot {
            Divider()
            Button("Rename…") { perform(.rename) }
            Button("Delete", role: .destructive) { perform(.delete) }
        }
    }
}

// MARK: - NameEntry

/// What the name prompt sheet is collecting a name for.
private enum NameEntry: Identifiable {
    case newFile(in: URL)
    case newFolder(in: URL)
    case rename(URL)

    var id: String {
        switch self {
        case .newFile(let dir):   return "file:\(dir.path)"
        case .newFolder(let dir): return "folder:\(dir.path)"
        case .rename(let url):    return "rename:\(url.path)"
        }
    }

    var title: String {
        switch self {
        case .newFile(let dir):   return "New File in \(dir.lastPathComponent)"
        case .newFolder(let dir): return "New Folder in \(dir.lastPathComponent)"
        case .rename(let url):    return "Rename \"\(url.lastPathComponent)\""
        }
    }

    var confirmLabel: String {
        switch self {
        case .newFile, .newFolder: return "Create"
        case .rename:              return "Rename"
        }
    }

    var initialText: String {
        if case .rename(let url) = self { return url.lastPathComponent }
        return ""
    }

    var placeholder: String {
        switch self {
        case .newFile:   return "name.ext or path/to/name.ext"
        case .newFolder: return "folder or path/to/folder"
        case .rename:    return "New name"
        }
    }
}

// MARK: - FileNodeRow

private struct FileNodeRow<Menu: View>: View {
    let node: FileNode
    let onTap: () -> Void
    @ViewBuilder let menu: () -> Menu
    @Environment(AppState.self) private var appState

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: appState.sf(4)) {
            // Indentation
            Color.clear
                .frame(width: CGFloat(node.depth) * appState.sf(14), height: 1)

            // Chevron (directories only)
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: appState.sf(10), weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(node.isExpanded ? .degrees(90) : .degrees(0))
                    .animation(.easeInOut(duration: 0.15), value: node.isExpanded)
                    .frame(width: appState.sf(14))
            } else {
                Color.clear.frame(width: appState.sf(14))
            }

            // File/folder icon
            fileIcon
                .font(.system(size: appState.sf(13)))
                .frame(width: appState.sf(16))

            // Filename
            Text(node.name)
                .font(.system(size: appState.sf(13)))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.leading, appState.sf(4))
        .padding(.vertical, appState.sf(2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onTap() }
        .contextMenu { menu() }
    }

    @ViewBuilder
    private var fileIcon: some View {
        if node.isDirectory {
            MaterialFileIcon(
                url: node.url, isDirectory: true, isExpanded: node.isExpanded,
                size: appState.sf(14),
                fallbackSystemName: "folder.fill", fallbackColor: .orange
            )
        } else {
            let lang = Language.detect(from: node.url)
            MaterialFileIcon(
                url: node.url, size: appState.sf(14),
                fallbackSystemName: iconName(for: lang), fallbackColor: iconColor(for: lang)
            )
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
        case .image:
            return "photo.fill"
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
        case .image:      return .pink
        case .plaintext:  return .secondary
        }
    }
}

// MARK: - NameEntrySheet

private struct NameEntrySheet: View {
    let entry: NameEntry
    let onConfirm: (String) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(12)) {
            Text(entry.title)
                .font(.system(size: appState.sf(13), weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            TextField(entry.placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { commit() }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(entry.confirmLabel) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(appState.sf(20))
        .frame(width: appState.sf(360))
        .onAppear {
            text = entry.initialText
            isFocused = true
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}
