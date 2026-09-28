// ToolNoticeBanner.swift
// Athena — banner above the status bar naming a missing tool and how to install it.
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

// MARK: - ToolNoticeBanner

struct ToolNoticeBanner: View {
    @Environment(AppState.self) private var appState

    let notice: ToolNotice

    @State private var copied = false

    var body: some View {
        HStack(spacing: appState.sf(10)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: appState.sf(2)) {
                Text(notice.title)
                    .font(.system(size: appState.sf(12), weight: .semibold))
                Text(notice.detail)
                    .font(.system(size: appState.sf(11.5)))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: appState.sf(8))

            Text(notice.installCommand)
                .font(.system(size: appState.sf(11.5), design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, appState.sf(8))
                .padding(.vertical, appState.sf(4))
                .background(
                    RoundedRectangle(cornerRadius: appState.sf(5), style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )

            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(notice.installCommand, forType: .string)
                copied = true
            }
            .controlSize(.small)
            .help("Copy the install command, then run it in Terminal")

            Button {
                appState.dismissToolNotice(notice.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: appState.sf(10), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: appState.sf(18), height: appState.sf(18))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don't show this again")
        }
        .padding(.horizontal, appState.sf(12))
        .padding(.vertical, appState.sf(7))
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}
