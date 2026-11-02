// GitOperationBanner.swift
// Athena — banner shown while a merge, rebase or cherry-pick is paused,
// with Continue and Abort.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - GitOperationBanner

struct GitOperationBanner: View {
    @Environment(AppState.self) private var appState

    let operation: GitOperation

    var body: some View {
        let conflicts = appState.gitStatus.conflicted.count
        HStack(spacing: appState.sf(8)) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(operation.title) in progress")
                    .font(.system(size: appState.sf(11), weight: .semibold))
                Text(conflicts > 0 ? "\(conflicts) conflicted file\(conflicts == 1 ? "" : "s")" : "No conflicts left")
                    .font(.system(size: appState.sf(10)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Continue") { Task { await appState.continueGitOperation() } }
                .disabled(conflicts > 0)
            Button("Abort", role: .destructive) { Task { await appState.abortGitOperation() } }
        }
        .controlSize(.small)
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(6))
        .background(Color.orange.opacity(0.12))
    }
}
