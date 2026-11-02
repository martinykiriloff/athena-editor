// PullRequestStatusView.swift
// Athena — pull request + CI status for the current branch via the `gh` CLI.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - PullRequestStatusView

/// Sheet shown from the Source Control actions menu. The menu item only
/// exists when `gh` was found, so this view never has to explain a missing CLI.
struct PullRequestStatusView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(10)) {
            HStack {
                Text("Pull Request").font(.system(size: appState.sf(14), weight: .semibold))
                Spacer()
                if appState.gitExtras.isLoadingPullRequest { ProgressView().controlSize(.small) }
                Button { Task { await appState.refreshPullRequest() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }

            if let pr = appState.gitExtras.pullRequest {
                VStack(alignment: .leading, spacing: appState.sf(4)) {
                    Text("#\(pr.number)  \(pr.title)").font(.system(size: appState.sf(13), weight: .medium))
                    Text("\(pr.headBranch)  ·  \(pr.isDraft ? "DRAFT" : pr.state)"
                         + (pr.reviewDecision.isEmpty ? "" : "  ·  \(pr.reviewDecision)"))
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(.secondary)
                    if let url = URL(string: pr.url) {
                        Link("Open on GitHub", destination: url).font(.system(size: appState.sf(11)))
                    }
                }
                Divider()
                if appState.gitExtras.checks.isEmpty {
                    Text("No CI checks reported.").foregroundStyle(.secondary)
                } else {
                    ForEach(appState.gitExtras.checks) { check in
                        HStack(spacing: appState.sf(6)) {
                            Image(systemName: icon(check.bucket)).foregroundStyle(color(check.bucket))
                            Text(check.workflow.isEmpty ? check.name : "\(check.workflow) / \(check.name)")
                                .font(.system(size: appState.sf(12)))
                            Spacer()
                            if let url = URL(string: check.link), !check.link.isEmpty {
                                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            }
                        }
                    }
                }
            } else if let message = appState.gitExtras.pullRequestMessage {
                Text(message).foregroundStyle(.secondary)
            }

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(appState.sf(14))
        .frame(width: appState.sf(480))
        .task { await appState.refreshPullRequest() }
    }

    private func icon(_ bucket: String) -> String {
        switch bucket {
        case "pass":     return "checkmark.circle.fill"
        case "fail":     return "xmark.circle.fill"
        case "skipping", "cancel": return "minus.circle"
        default:         return "clock"
        }
    }

    private func color(_ bucket: String) -> Color {
        switch bucket {
        case "pass": return .green
        case "fail": return .red
        default:     return .secondary
        }
    }
}
