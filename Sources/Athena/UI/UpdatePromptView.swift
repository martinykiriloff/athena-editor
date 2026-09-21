// UpdatePromptView.swift
// Athena — "a new version is available" sheet: release notes plus install / later / skip.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

// MARK: - UpdatePromptView

struct UpdatePromptView: View {
    @Environment(AppState.self)      private var appState
    @Environment(UpdateService.self) private var updateService

    /// Captured when the sheet opens, so the notes and version stay on
    /// screen while the state moves on to downloading.
    @State private var release: UpdateRelease?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            notes
            footer
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { release = updateService.availableRelease }
        .onChange(of: updateService.availableRelease) { _, new in
            if let new { release = new }
        }
        .interactiveDismissDisabled(isBusy)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("A new version of Athena is available")
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        let latest = release?.version ?? "—"
        guard let current = updateService.currentVersion else { return "Athena \(latest) is ready to install." }
        return "Athena \(latest) is available — you have \(current). Would you like to update now?"
    }

    // MARK: - Release notes

    @ViewBuilder
    private var notes: some View {
        let text = release?.notes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Release Notes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(renderedNotes(text))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
            }
        }
    }

    /// GitHub release notes are markdown; render inline styling (bold,
    /// code, links) and keep the line structure of lists and headings.
    private func renderedNotes(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch updateService.state {
        case .downloading, .readyToInstall:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progressLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 28)

        case .error(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer()
                Button("Close") { updateService.isPromptPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { Task { await updateService.checkForUpdates() } }
                    .keyboardShortcut(.defaultAction)
            }

        default:
            HStack(spacing: 8) {
                Button("Skip This Version") { Task { await updateService.skipAvailableVersion() } }
                if let page = release?.pageURL {
                    Button("View on GitHub") { NSWorkspace.shared.open(page) }
                }
                Spacer()
                Button("Remind Me Later") { updateService.remindLater() }
                    .keyboardShortcut(.cancelAction)
                Button("Install and Restart") { install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(updateService.availableRelease == nil)
            }
            if hasUnsavedUntitledTabs {
                Text("Untitled tabs with unsaved changes will be lost when Athena restarts. Other open files are saved automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isBusy: Bool {
        switch updateService.state {
        case .downloading, .readyToInstall: return true
        default: return false
        }
    }

    private var progressLabel: String {
        if case .readyToInstall = updateService.state { return "Saving files and restarting…" }
        return "Downloading Athena \(release?.version ?? "")…"
    }

    private var hasUnsavedUntitledTabs: Bool {
        let tabs = appState.openTabs + (appState.secondaryGroup?.tabs ?? [])
        return tabs.contains { $0.fileURL == nil && $0.isDirty }
    }

    private func install() {
        Task {
            await updateService.install { await appState.saveAllTabs() }
        }
    }
}
