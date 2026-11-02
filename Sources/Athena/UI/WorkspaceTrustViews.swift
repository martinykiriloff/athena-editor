// WorkspaceTrustViews.swift
// Athena — trust prompt overlay and the Restricted Mode banner.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - Prompt

struct WorkspaceTrustPromptView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Label("Do you trust the authors of this folder?", systemImage: "lock.shield")
                    .font(.headline)
                Text("\(appState.workspace?.rootURL.lastPathComponent ?? "This folder") may contain tasks, npm scripts, debug configurations or tool binaries that run code on your Mac. In Restricted Mode they are disabled; you can trust the folder later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Open in Restricted Mode") { Task { await appState.setTrust(.restricted) } }
                        .accessibilityHint("Keeps tasks, scripts, debugging and workspace tools disabled")
                    Button("Trust Folder") { Task { await appState.setTrust(.trusted) } }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Allows this folder to run tasks, scripts and tools")
                }
            }
            .padding(20)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Workspace trust")
        }
    }
}

// MARK: - Banner

struct RestrictedModeBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(appState.trust.lastBlocked.map { TrustPolicy.blockedMessage(for: $0) }
                 ?? "Restricted Mode: tasks, npm scripts, debugging, workspace tools and SFCC uploads are disabled.")
                .font(.system(size: 11.5))
                .lineLimit(2)
            Spacer()
            Button("Trust Workspace") { Task { await appState.setTrust(.trusted) } }
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Restricted Mode")
    }
}
