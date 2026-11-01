// TaskPickerView.swift
// Athena — "Run Task…" palette listing the tasks from .vscode/tasks.json.
// Swift 6, strict concurrency.

import SwiftUI

struct TaskPickerView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    /// Fuzzy-filtered tasks; build-group tasks first when the query is empty.
    private var matches: [TaskDefinition] {
        let tasks = appState.taskCenter.tasks
        if query.isEmpty {
            return tasks.sorted { ($0.group == .build ? 0 : 1) < ($1.group == .build ? 0 : 1) }
        }
        return tasks
            .compactMap { task in fuzzyNameScore(query: query, target: task.label).map { (task, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: appState.sf(8)) {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: appState.sf(14)))
                    TextField("Select the task to run", text: $query)
                        .font(.system(size: appState.sf(16)))
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onKeyPress(.upArrow)   { move(-1); return .handled }
                        .onKeyPress(.downArrow) { move(1);  return .handled }
                        .onKeyPress(.return)    { confirm(); return .handled }
                        .onKeyPress(.escape)    { close();   return .handled }
                }
                .padding(.horizontal, appState.sf(12))
                .padding(.vertical, appState.sf(10))

                let list = matches
                Divider()
                if list.isEmpty {
                    Text("No matching tasks")
                        .foregroundStyle(.secondary)
                        .font(.system(size: appState.sf(12)))
                        .padding(appState.sf(20))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, task in
                                    TaskPickerRow(task: task, isSelected: i == selectedIndex)
                                        .id(task.id)
                                        .onTapGesture { run(task) }
                                }
                            }
                        }
                        .frame(maxHeight: appState.sf(360))
                        .onChange(of: selectedIndex) { _, idx in
                            guard list.indices.contains(idx) else { return }
                            proxy.scrollTo(list[idx].id, anchor: .center)
                        }
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: appState.sf(10)))
            .shadow(color: .black.opacity(0.5), radius: appState.sf(24), x: 0, y: appState.sf(12))
            .frame(width: appState.sf(580))
            .padding(.top, appState.sf(80))
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { selectedIndex = 0 }
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func confirm() {
        let list = matches
        guard list.indices.contains(selectedIndex) else { return }
        run(list[selectedIndex])
    }

    private func run(_ task: TaskDefinition) {
        appState.runWorkspaceTask(label: task.label)
        close()
    }

    private func close() {
        appState.taskCenter.showPicker = false
    }
}

// MARK: - Row

private struct TaskPickerRow: View {
    let task: TaskDefinition
    let isSelected: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: appState.sf(8)) {
            Image(systemName: task.group == .build ? "hammer" : task.group == .test ? "checkmark.seal" : "terminal")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: appState.sf(14))

            VStack(alignment: .leading, spacing: appState.sf(1)) {
                Text(task.label)
                    .font(.system(size: appState.sf(13)))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                Text(task.detail ?? ([task.command] + task.args).joined(separator: " "))
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(isSelected ? .white.opacity(0.65) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, appState.sf(12))
        .padding(.vertical, appState.sf(6))
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}
