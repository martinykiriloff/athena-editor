// MergeEditorView.swift
// Athena — 3-way merge editor: per-conflict Accept Current / Incoming / Both
// with a live preview of the resulting file.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - MergeEditorView

/// Presented as a sheet from Source Control for one conflicted file. Shows
/// every `<<<<<<<` region as a card (current vs incoming side by side) and a
/// result pane built by `MergeResolution.apply`. "Save & Stage" writes the
/// result and runs `git add`, which is what marks the file resolved.
/// The common-ancestor (base) text is not shown.
struct MergeEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let path: String

    @State private var original: String?
    @State private var regions: [ConflictRegion] = []
    @State private var choices: [Int: ConflictResolutionChoice] = [:]

    private var resolved: String {
        guard let original else { return "" }
        return MergeResolution.apply(choices: choices, regions: regions, to: original)
    }

    private var allResolved: Bool { !regions.isEmpty && choices.count == regions.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if original == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if regions.isEmpty {
                Text("No conflict markers left in this file. Save & Stage to mark it resolved.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    ScrollView {
                        LazyVStack(spacing: appState.sf(8)) {
                            ForEach(Array(regions.enumerated()), id: \.offset) { index, region in
                                ConflictCard(index: index, region: region, choice: choices[index]) { choice in
                                    if let choice { choices[index] = choice } else { choices.removeValue(forKey: index) }
                                }
                            }
                        }
                        .padding(appState.sf(10))
                    }
                    .frame(minHeight: appState.sf(160))
                    resultPane
                        .frame(minHeight: appState.sf(120))
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: appState.sf(820), minHeight: appState.sf(560))
        .task {
            let text = await appState.mergeEditorText(for: path) ?? ""
            original = text
            regions = ConflictParser.parse(text)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.merge")
            Text(path).font(.system(size: appState.sf(13), weight: .semibold)).lineLimit(1).truncationMode(.head)
            Spacer()
            if !regions.isEmpty {
                Text("\(choices.count) of \(regions.count) resolved")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
                Button("All Current") { applyAll(.ours) }
                Button("All Incoming") { applyAll(.theirs) }
            }
        }
        .padding(appState.sf(10))
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RESULT")
                .font(.system(size: appState.sf(10), weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, appState.sf(10))
                .padding(.vertical, appState.sf(4))
            ScrollView([.vertical, .horizontal]) {
                Text(resolved)
                    .font(.system(size: appState.sf(11), design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(appState.sf(10))
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var footer: some View {
        HStack {
            if !regions.isEmpty, !allResolved {
                Text("Choose a side for every conflict to enable saving.")
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save & Stage") {
                let text = resolved
                Task {
                    await appState.saveMergeResolution(path: path, text: text)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(original == nil || (!regions.isEmpty && !allResolved))
        }
        .padding(appState.sf(10))
    }

    private func applyAll(_ choice: ConflictResolutionChoice) {
        for index in regions.indices { choices[index] = choice }
    }
}

// MARK: - ConflictCard

private struct ConflictCard: View {
    @Environment(AppState.self) private var appState

    let index: Int
    let region: ConflictRegion
    let choice: ConflictResolutionChoice?
    let onChoose: (ConflictResolutionChoice?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(6)) {
            HStack {
                Text("Conflict \(index + 1)  ·  lines \(region.startLine)–\(region.endLine)")
                    .font(.system(size: appState.sf(11), weight: .semibold))
                Spacer()
                chooser("Accept Current", .ours)
                chooser("Accept Incoming", .theirs)
                chooser("Accept Both", .both)
            }
            HStack(alignment: .top, spacing: appState.sf(8)) {
                side(title: "Current" + (region.oursLabel.isEmpty ? "" : " (\(region.oursLabel))"),
                     text: region.oursText, color: Color(nsColor: appState.currentTheme.diffRemoved),
                     dimmed: choice == .theirs)
                side(title: "Incoming" + (region.theirsLabel.isEmpty ? "" : " (\(region.theirsLabel))"),
                     text: region.theirsText, color: Color(nsColor: appState.currentTheme.diffAdded),
                     dimmed: choice == .ours)
            }
        }
        .padding(appState.sf(8))
        .background(RoundedRectangle(cornerRadius: appState.sf(6)).fill(Color.secondary.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: appState.sf(6))
                .stroke(choice == nil ? Color.orange.opacity(0.6) : Color.green.opacity(0.5), lineWidth: 1)
        )
    }

    private func chooser(_ title: String, _ value: ConflictResolutionChoice) -> some View {
        Button(title) { onChoose(choice == value ? nil : value) }
            .buttonStyle(.bordered)
            .tint(choice == value ? .green : nil)
            .controlSize(.small)
    }

    private func side(title: String, text: String, color: Color, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: appState.sf(2)) {
            Text(title).font(.system(size: appState.sf(10), weight: .medium)).foregroundStyle(.secondary)
            Text(text.isEmpty ? "(empty)" : text)
                .font(.system(size: appState.sf(11), design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(appState.sf(6))
                .background(color.opacity(dimmed ? 0.05 : 0.18))
                .opacity(dimmed ? 0.5 : 1)
                .cornerRadius(appState.sf(4))
        }
        .frame(maxWidth: .infinity)
    }
}
