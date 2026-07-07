// DBDataBrowserView.swift — Table browser + editable data grid for a
// connected PostgreSQL database (DBConnectionsView opens this on Connect).
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - DBDataBrowserView

struct DBDataBrowserView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let connection: DBConnection

    @State private var selectedTableId: String?

    var body: some View {
        NavigationSplitView {
            List(appState.dbBrowserTables, selection: $selectedTableId) { table in
                Label(table.name, systemImage: "tablecells")
                    .tag(table.id)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 220)
        } detail: {
            detailContent
        }
        .frame(minWidth: 940, minHeight: 580)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { dismiss() }
            }
        }
        .onChange(of: selectedTableId) { _, newId in
            guard let newId, let table = appState.dbBrowserTables.first(where: { $0.id == newId }) else { return }
            Task { await appState.loadDBTableData(table) }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if appState.dbBrowserIsLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = appState.dbBrowserErrorMessage {
            ContentUnavailableView(
                "Couldn't load data",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let data = appState.dbBrowserTableData {
            DBTableGridView(data: data)
        } else {
            ContentUnavailableView(
                "Select a Table",
                systemImage: "cylinder.split.1x2",
                description: Text("\(appState.dbBrowserTables.count) tables in \(connection.database.isEmpty ? connection.name : connection.database)")
            )
        }
    }
}

// MARK: - DBTableGridView

private struct DBTableGridView: View {
    let data: DBTableData

    private var isEditable: Bool { data.columns.contains(where: \.isPrimaryKey) }

    var body: some View {
        VStack(spacing: 0) {
            Table(data.rows) {
                TableColumnForEach(data.columns) { column in
                    TableColumn(column.name) { row in
                        DBCellView(row: row, column: column, isEditable: isEditable)
                    }
                }
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !isEditable {
                Label("Read-only — no primary key", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private var footerText: String {
        let count = data.rows.count
        let noun = count == 1 ? "row" : "rows"
        return data.isComplete ? "\(count) \(noun)" : "showing first \(count) \(noun)"
    }
}

// MARK: - DBCellView

/// One editable cell. Double-click to edit (Excel/Numbers convention);
/// Return commits, Escape cancels. Primary-key columns are never editable —
/// they're what edits use to address a row, so changing one out from under
/// itself is a footgun this MVP simply avoids rather than tries to handle.
private struct DBCellView: View {
    @Environment(AppState.self) private var appState
    let row: DBRow
    let column: DBColumn
    let isEditable: Bool

    @State private var isEditing = false
    @State private var text = ""

    private var currentValue: DBValue { row.values[column.name] ?? .null }
    private var canEditThisCell: Bool { isEditable && !column.isPrimaryKey }

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $text, onCommit: commit)
                    .textFieldStyle(.plain)
                    .onExitCommand { isEditing = false }
            } else {
                Text(currentValue == .null ? "NULL" : currentValue.displayString)
                    .foregroundStyle(currentValue == .null ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard canEditThisCell else { return }
                        text = currentValue.displayString
                        isEditing = true
                    }
            }
        }
    }

    private func commit() {
        isEditing = false
        guard text != currentValue.displayString else { return }
        let newValue = DBValue.parsing(text, matching: currentValue)
        Task { await appState.updateDBCell(rowId: row.id, column: column.name, newValue: newValue) }
    }
}
