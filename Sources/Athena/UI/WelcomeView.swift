// WelcomeView.swift
// Athena — start screen shown when no editor tabs are open.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

// MARK: - WelcomeView

struct WelcomeView: View {

    @Environment(AppState.self) private var appState

    // MARK: Body

    var body: some View {
        ZStack {
            // Editor background of the active theme, so the welcome screen
            // reads as part of the editor in light and dark themes alike.
            Color(nsColor: appState.currentTheme.background)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Branding ───────────────────────────────────────────────
                VStack(spacing: appState.sf(10)) {
                    Text("Athena")
                        .font(.system(size: appState.sf(48), weight: .bold, design: .default))
                        .foregroundStyle(.primary)

                    Text("AI-first macOS code editor")
                        .font(.system(size: appState.sf(16), weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Spacer().frame(height: appState.sf(48))

                // ── Quick actions ──────────────────────────────────────────
                HStack(spacing: appState.sf(16)) {
                    QuickActionButton(
                        title: "Open Folder",
                        systemImage: "folder.badge.plus",
                        shortcut: "⌘O"
                    ) {
                        openFolder()
                    }

                    QuickActionButton(
                        title: "New File",
                        systemImage: "doc.badge.plus",
                        shortcut: "⌘N"
                    ) {
                        newFile()
                    }

                    QuickActionButton(
                        title: "Clone Repository",
                        systemImage: "arrow.triangle.branch",
                        shortcut: nil
                    ) {
                        cloneRepository()
                    }
                }

                // ── Recent folders ─────────────────────────────────────────
                RecentWorkspacesList()
                    .padding(.top, appState.sf(40))

                Spacer().frame(height: appState.sf(40))

                // ── Keyboard shortcuts reference ───────────────────────────
                ShortcutsGrid()

                Spacer()
            }
            .padding(.horizontal, appState.sf(48))
        }
    }

    // MARK: Actions

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to open as a workspace"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await appState.openWorkspace(url)
        }
    }

    private func newFile() {
        // WelcomeView only ever renders in the primary pane's empty state
        // (plan.md item 22 — a second group always seeds itself with a tab).
        appState.openNewTab(in: .primary)
    }

    /// Prompts for a repo URL, then a destination folder to clone into (an
    /// `NSOpenPanel` folder-picker matching `openFolder()`'s pattern above),
    /// then hands off to `AppState.cloneRepository(urlString:destinationParent:)`
    /// (plan.md item 20 point 3). Progress and failures surface via
    /// `appState.statusMessage` — the status bar is always visible, including
    /// on this Welcome screen.
    private func cloneRepository() {
        guard let urlString = promptForRepositoryURL() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Clone Here"
        panel.message = "Choose a folder to clone \"\(urlString)\" into"

        guard panel.runModal() == .OK, let destinationParent = panel.url else { return }

        Task {
            await appState.cloneRepository(urlString: urlString, destinationParent: destinationParent)
        }
    }

    /// NSAlert-with-accessory-`NSTextField` prompt, matching
    /// `EditorView.Coordinator.promptGoToLine`/`promptRenameSymbol`'s pattern.
    private func promptForRepositoryURL() -> String? {
        let alert = NSAlert()
        alert.messageText = "Clone Repository"
        alert.informativeText = "Enter the repository URL:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://github.com/user/repo.git"
        alert.accessoryView = field
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let urlString = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return urlString.isEmpty ? nil : urlString
    }
}

// MARK: - QuickActionButton

private struct QuickActionButton: View {

    let title: String
    let systemImage: String
    let shortcut: String?
    let action: () -> Void
    @Environment(AppState.self) private var appState

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: appState.sf(10)) {
                Image(systemName: systemImage)
                    .font(.system(size: appState.sf(24)))
                    .foregroundStyle(isHovered ? .white : Color.accentColor)

                Text(title)
                    .font(.system(size: appState.sf(13), weight: .medium))
                    .foregroundStyle(.primary)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: appState.sf(130), height: appState.sf(100))
            .background(
                RoundedRectangle(cornerRadius: appState.sf(10), style: .continuous)
                    .fill(
                        isHovered
                            ? Color(nsColor: appState.currentTheme.selection)
                            : Color(nsColor: appState.currentTheme.lineHighlight)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: appState.sf(10), style: .continuous)
                    .strokeBorder(
                        Color(nsColor: appState.currentTheme.whitespace),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - RecentWorkspacesList

/// Recently opened folders: click to open, × to drop one from the list.
/// Folders that no longer exist are left out.
private struct RecentWorkspacesList: View {
    @Environment(AppState.self) private var appState
    /// Read only so SwiftUI redraws when the list changes.
    @AppStorage(AppState.recentWorkspacesKey) private var storedPaths = ""

    private static let shown = 6

    private var paths: [String] {
        _ = storedPaths
        return AppState.recentWorkspacePaths()
            .filter { FileManager.default.fileExists(atPath: $0) }
            .prefix(Self.shown)
            .map { $0 }
    }

    var body: some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: appState.sf(2)) {
                Text("Recent")
                    .font(.system(size: appState.sf(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, appState.sf(10))
                    .padding(.bottom, appState.sf(4))

                ForEach(paths, id: \.self) { path in
                    RecentWorkspaceRow(path: path) {
                        Task { await appState.openWorkspace(URL(fileURLWithPath: path)) }
                    } onRemove: {
                        AppState.removeRecentWorkspace(path)
                        // `removeRecentWorkspace` writes through UserDefaults
                        // directly; mirror it so the list redraws.
                        storedPaths = UserDefaults.standard.string(forKey: AppState.recentWorkspacesKey) ?? ""
                    }
                }
            }
            .frame(maxWidth: appState.sf(480))
        }
    }
}

// MARK: - RecentWorkspaceRow

private struct RecentWorkspaceRow: View {
    @Environment(AppState.self) private var appState

    let path: String
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    /// The parent folder with the home directory shortened to `~`.
    private var location: String {
        let parent = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    var body: some View {
        HStack(spacing: appState.sf(8)) {
            Image(systemName: "folder")
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(Color.accentColor)
                .frame(width: appState.sf(16))

            Text((path as NSString).lastPathComponent)
                .font(.system(size: appState.sf(13), weight: .medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)

            Text(location)
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: appState.sf(8))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: appState.sf(9), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: appState.sf(18), height: appState.sf(18))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Remove from Recent")
        }
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(5))
        .background(
            RoundedRectangle(cornerRadius: appState.sf(6), style: .continuous)
                .fill(isHovered ? Color(nsColor: appState.currentTheme.lineHighlight) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .help(path)
    }
}

// MARK: - ShortcutsGrid

private struct ShortcutsGrid: View {
    @Environment(AppState.self) private var appState

    private let shortcuts: [(key: String, description: String)] = [
        ("⌘P",  "Go to File"),
        ("⌘O",  "Open Folder"),
        ("⌘B",  "Toggle Sidebar"),
        ("⌃`",  "Toggle Terminal"),
        ("⇧⌘P", "Command Palette")
    ]

    // Two-column layout
    private var rows: [[(key: String, description: String)]] {
        stride(from: 0, to: shortcuts.count, by: 2).map { start in
            let end = min(start + 2, shortcuts.count)
            return Array(shortcuts[start..<end])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(8)) {
            Text("Keyboard Shortcuts")
                .font(.system(size: appState.sf(11), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, appState.sf(4))

            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: appState.sf(24)) {
                    ForEach(rows[rowIndex].indices, id: \.self) { colIndex in
                        ShortcutRow(item: rows[rowIndex][colIndex])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Pad odd rows so grid stays aligned
                    if rows[rowIndex].count == 1 {
                        Spacer()
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, appState.sf(32))
        .padding(.vertical, appState.sf(20))
        .background(
            RoundedRectangle(cornerRadius: appState.sf(12), style: .continuous)
                .fill(Color(nsColor: appState.currentTheme.lineHighlight))
        )
        .frame(maxWidth: appState.sf(480))
    }
}

// MARK: - ShortcutRow

private struct ShortcutRow: View {
    @Environment(AppState.self) private var appState

    let item: (key: String, description: String)

    var body: some View {
        HStack(spacing: appState.sf(10)) {
            Text(item.key)
                .font(.system(size: appState.sf(12), weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, appState.sf(6))
                .padding(.vertical, appState.sf(3))
                .background(
                    RoundedRectangle(cornerRadius: appState.sf(5), style: .continuous)
                        .fill(Color(nsColor: appState.currentTheme.selection))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: appState.sf(5), style: .continuous)
                        .strokeBorder(
                            Color(nsColor: appState.currentTheme.whitespace),
                            lineWidth: 1
                        )
                )
                .frame(minWidth: appState.sf(44), alignment: .center)

            Text(item.description)
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

