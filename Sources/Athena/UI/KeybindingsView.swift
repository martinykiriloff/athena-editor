// KeybindingsView.swift — GUI table for editing keybindings + "Open JSON" button.

import SwiftUI
import AppKit

// MARK: - KeybindingsView

struct KeybindingsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var recorder = KeyRecorder()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            bindingsList
        }
        .onDisappear { recorder.stop() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            TextField("Search bindings…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button("Reset All") {
                Task { await appState.resetAllKeyBindings() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!appState.keyBindings.contains(where: \.isCustomized))

            Button("Open JSON") { openJSONFile() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: List

    private var bindingsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(KeyBinding.categories, id: \.self) { category in
                    let rows = filtered(category: category)
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { binding in
                                BindingRow(
                                    binding: binding,
                                    isRecording: recorder.recordingFor == binding.action,
                                    onEdit: { startRecording(for: binding.action) },
                                    onReset: { Task { await appState.resetKeyBinding(action: binding.action) } }
                                )
                                Divider().padding(.leading, 14)
                            }
                        } header: {
                            categoryHeader(category)
                        }
                    }
                }
            }
        }
    }

    private func categoryHeader(_ name: String) -> some View {
        HStack {
            Text(name.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Helpers

    private func filtered(category: String) -> [KeyBinding] {
        let inCategory = appState.keyBindings.filter { $0.action.category == category }
        guard !searchText.isEmpty else { return inCategory }
        let q = searchText.lowercased()
        return inCategory.filter {
            $0.action.displayName.lowercased().contains(q) ||
            ($0.combo?.displayString.lowercased().contains(q) ?? false)
        }
    }

    private func startRecording(for action: KeyAction) {
        if recorder.recordingFor == action {
            recorder.stop()
            return
        }
        recorder.start(for: action) { recordedAction, combo in
            Task { await appState.setKeyBinding(action: recordedAction, combo: combo) }
        }
    }

    private func openJSONFile() {
        Task {
            await appState.keyBindingService.ensureFileExists()
            let url = await appState.keyBindingService.jsonFileURL
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - BindingRow

private struct BindingRow: View {
    let binding: KeyBinding
    let isRecording: Bool
    let onEdit: () -> Void
    let onReset: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Action name
            Text(binding.action.displayName)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Binding chip / recording state
            if isRecording {
                RecordingChip()
            } else {
                ComboChip(combo: binding.combo, isCustomized: binding.isCustomized)
            }

            // Edit button
            Button(action: onEdit) {
                Image(systemName: isRecording ? "stop.circle" : "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Cancel recording" : "Edit shortcut")
            .opacity(isHovered || isRecording ? 1 : 0)

            // Reset button (only if customized)
            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Reset to default")
            .opacity(binding.isCustomized && isHovered ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(isRecording ? Color.accentColor.opacity(0.07) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - ComboChip

private struct ComboChip: View {
    let combo: KeyCombo?
    let isCustomized: Bool

    var body: some View {
        Group {
            if let combo {
                Text(combo.displayString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isCustomized ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isCustomized
                                  ? Color.accentColor.opacity(0.1)
                                  : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(
                                isCustomized
                                    ? Color.accentColor.opacity(0.3)
                                    : Color.secondary.opacity(0.2),
                                lineWidth: 1
                            )
                    )
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 40)
            }
        }
    }
}

// MARK: - RecordingChip

private struct RecordingChip: View {
    @State private var visible = true

    var body: some View {
        Text("Press keys…")
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .opacity(visible ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = false }
    }
}
