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
            // Darcula editor background — matches the surrounding chrome.
            Color(NSColor(calibratedRed: 0.157, green: 0.173, blue: 0.204, alpha: 1.0))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Branding ───────────────────────────────────────────────
                VStack(spacing: 10) {
                    Text("Athena")
                        .font(.system(size: appState.sf(48), weight: .bold, design: .default))
                        .foregroundStyle(.white)

                    Text("AI-first macOS code editor")
                        .font(.system(size: appState.sf(16), weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Spacer().frame(height: 48)

                // ── Quick actions ──────────────────────────────────────────
                HStack(spacing: 16) {
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
                        // Placeholder — git clone UI not yet implemented.
                    }
                }

                Spacer().frame(height: 56)

                // ── Keyboard shortcuts reference ───────────────────────────
                ShortcutsGrid()

                Spacer()
            }
            .padding(.horizontal, 48)
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
        appState.openNewTab()
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
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: appState.sf(24)))
                    .foregroundStyle(isHovered ? .white : Color.accentColor)

                Text(title)
                    .font(.system(size: appState.sf(13), weight: .medium))
                    .foregroundStyle(.white)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, height: 100)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isHovered
                            ? Color(NSColor(calibratedRed: 0.26, green: 0.29, blue: 0.35, alpha: 1))
                            : Color(NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color(NSColor(calibratedRed: 0.30, green: 0.33, blue: 0.40, alpha: 1)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard Shortcuts")
                .font(.system(size: appState.sf(11), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 4)

            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 24) {
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
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.24, alpha: 1)))
        )
        .frame(maxWidth: 480)
    }
}

// MARK: - ShortcutRow

private struct ShortcutRow: View {
    @Environment(AppState.self) private var appState

    let item: (key: String, description: String)

    var body: some View {
        HStack(spacing: 10) {
            Text(item.key)
                .font(.system(size: appState.sf(12), weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(NSColor(calibratedRed: 0.26, green: 0.29, blue: 0.36, alpha: 1)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            Color(NSColor(calibratedRed: 0.36, green: 0.40, blue: 0.48, alpha: 1)),
                            lineWidth: 1
                        )
                )
                .frame(minWidth: 44, alignment: .center)

            Text(item.description)
                .font(.system(size: appState.sf(12)))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

