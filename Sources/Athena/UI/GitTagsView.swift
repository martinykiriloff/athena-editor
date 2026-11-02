// GitTagsView.swift
// Athena — create and delete tags (sheet from Source Control).
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - GitTagsView

struct GitTagsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var message = ""
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(10)) {
            Text("Tags").font(.system(size: appState.sf(14), weight: .semibold))

            VStack(alignment: .leading, spacing: appState.sf(6)) {
                TextField("Tag name (e.g. v1.2.0)", text: $name)
                TextField("Message (optional — makes it an annotated tag)", text: $message)
                TextField("Commit (blank = HEAD)", text: $target)
                HStack {
                    Spacer()
                    Button("Create Tag") {
                        let n = name, m = message, t = target
                        Task {
                            await appState.createTag(name: n, target: t.isEmpty ? nil : t, message: m)
                            name = ""; message = ""
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .textFieldStyle(.roundedBorder)

            Divider()

            if appState.gitExtras.tags.isEmpty {
                Text("No tags yet.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: appState.sf(60))
            } else {
                List(appState.gitExtras.tags) { tag in
                    HStack {
                        Image(systemName: tag.isAnnotated ? "tag.fill" : "tag")
                        VStack(alignment: .leading) {
                            Text(tag.name).font(.system(size: appState.sf(12), weight: .medium))
                            Text(tag.shortHash + (tag.subject.isEmpty ? "" : "  ·  " + tag.subject))
                                .font(.system(size: appState.sf(10)))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await appState.deleteTag(tag) }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete tag locally")
                    }
                }
                .frame(minHeight: appState.sf(160))
            }

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(appState.sf(14))
        .frame(width: appState.sf(460))
        .onAppear { target = appState.gitExtras.tagTarget ?? "" }
    }
}
