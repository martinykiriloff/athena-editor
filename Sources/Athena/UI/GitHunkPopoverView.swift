// GitHunkPopoverView.swift
// Athena — small popover opened from the editor gutter's change bar: stage,
// unstage or revert the hunk under the click.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - Notification

extension Notification.Name {
    /// Posted by `EditorView` when a gutter hunk action is chosen. `userInfo`
    /// carries "path" (file path), "line" (Int) and "action" (String).
    static let athenaGitHunkAction = Notification.Name("athena.gitHunkAction")
}

extension GitHunkAction {
    var notificationName: String {
        switch self {
        case .stage:   return "stage"
        case .unstage: return "unstage"
        case .revert:  return "revert"
        }
    }

    init?(notificationName: String) {
        switch notificationName {
        case "stage":   self = .stage
        case "unstage": self = .unstage
        case "revert":  self = .revert
        default:        return nil
        }
    }
}

// MARK: - GitHunkPopoverView

struct GitHunkPopoverView: View {
    let onAction: (GitHunkAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { onAction(.stage) } label: { Label("Stage Hunk", systemImage: "plus.circle") }
            Button { onAction(.unstage) } label: { Label("Unstage Hunk", systemImage: "minus.circle") }
            Divider()
            Button(role: .destructive) { onAction(.revert) } label: { Label("Revert Hunk", systemImage: "arrow.uturn.backward") }
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}
