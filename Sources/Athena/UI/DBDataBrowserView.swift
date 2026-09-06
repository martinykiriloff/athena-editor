// DBDataBrowserView.swift — Table browser, editable data grid and SQL query
// console for a connected database (DBConnectionsView opens this on Connect).
// Swift 6, strict concurrency.

import SwiftUI
@preconcurrency import AppKit
import UniformTypeIdentifiers

// MARK: - DBDataBrowserView

struct DBDataBrowserView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let connection: DBConnection

    private enum Mode: String, CaseIterable {
        case browse = "Browse"
        case query = "Query"
    }

    @State private var selectedTableId: String?
    @State private var mode: Mode = .browse
    @State private var queryText: String = ""

    var body: some View {
        NavigationSplitView {
            List(appState.dbBrowserTables, selection: $selectedTableId) { table in
                Label(table.name, systemImage: "tablecells")
                    .tag(table.id)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .padding(8)
                Divider()
                switch mode {
                case .browse: browseContent
                case .query:  DBQueryConsoleView(queryText: $queryText, selectedTable: selectedTable)
                }
            }
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

    private var selectedTable: DBTableRef? {
        appState.dbBrowserTables.first { $0.id == selectedTableId }
    }

    @ViewBuilder
    private var browseContent: some View {
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
                description: Text("\(appState.dbBrowserTables.count) tables in \(connection.database.isEmpty ? connection.name : (connection.database as NSString).lastPathComponent)")
            )
        }
    }
}

// MARK: - DBQueryConsoleView

/// Editor above, result grid below. ⌘↩ runs the statement; the query text
/// lives in the parent so switching modes doesn't lose it.
private struct DBQueryConsoleView: View {
    @Environment(AppState.self) private var appState
    @Binding var queryText: String
    let selectedTable: DBTableRef?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                TextEditor(text: $queryText)
                    .font(.system(size: appState.sf(13), design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .onAppear {
                        if queryText.isEmpty, let table = selectedTable {
                            queryText = "SELECT * FROM \(table.qualifiedSQL) LIMIT 100;"
                        }
                    }
                Divider()
                HStack(spacing: 8) {
                    Button {
                        Task { await appState.runDBQuery(queryText) }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(appState.dbQueryIsRunning || queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("⌘↩")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if appState.dbQueryIsRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text("One statement per run")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
            }
            .frame(minHeight: 120)

            resultContent
                .frame(minHeight: 160)
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if let error = appState.dbQueryErrorMessage {
            ContentUnavailableView("Query failed", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let result = appState.dbQueryResult {
            if result.columns.isEmpty {
                ContentUnavailableView(
                    result.affectedRows.map { "\($0) row\($0 == 1 ? "" : "s") affected" } ?? "Statement executed",
                    systemImage: "checkmark.circle",
                    description: Text(elapsedText(result.elapsed))
                )
            } else {
                DBResultGridView(
                    columns: result.columns,
                    rows: result.rows,
                    footer: "\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")\(result.isTruncated ? " (truncated)" : "") · \(elapsedText(result.elapsed))"
                )
            }
        } else {
            ContentUnavailableView("No results yet", systemImage: "terminal", description: Text("Run a statement to see its rows here."))
        }
    }

    private func elapsedText(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.2f s", ms / 1000)
    }
}

// MARK: - DBResultGridView (read-only)

private struct DBResultGridView: View {
    let columns: [DBColumn]
    let rows: [DBRow]
    let footer: String

    var body: some View {
        VStack(spacing: 0) {
            Table(rows) {
                TableColumnForEach(columns) { column in
                    TableColumn(column.name) { row in
                        let value = row.values[column.name] ?? .null
                        Text(value == .null ? "NULL" : value.displayString)
                            .foregroundStyle(value == .null ? .tertiary : .primary)
                    }
                }
            }
            Divider()
            HStack {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                Spacer()
                DBExportButton(columns: columns, rows: rows, suggestedName: "query-result")
            }
            .padding(8)
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
            DBExportButton(columns: data.columns, rows: data.rows, suggestedName: data.table.name)
        }
        .padding(8)
    }

    private var footerText: String {
        let count = data.rows.count
        let noun = count == 1 ? "row" : "rows"
        return data.isComplete ? "\(count) \(noun)" : "showing first \(count) \(noun)"
    }
}

// MARK: - DBExportButton

/// "Export…" → save panel → CSV or JSON by the chosen extension. The grid's
/// rows are exported as fetched (same limit the grid shows).
private struct DBExportButton: View {
    let columns: [DBColumn]
    let rows: [DBRow]
    let suggestedName: String

    var body: some View {
        Menu {
            ForEach(DBExportFormat.allCases, id: \.self) { format in
                Button(format.rawValue.uppercased()) { export(format) }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(rows.isEmpty)
    }

    private func export(_ format: DBExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = DBExport.render(format, columns: columns, rows: rows)
        try? text.write(to: url, atomically: true, encoding: .utf8)
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
    @FocusState private var isFocused: Bool

    private var currentValue: DBValue { row.values[column.name] ?? .null }
    private var canEditThisCell: Bool { isEditable && !column.isPrimaryKey }

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $text, onCommit: commit)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    // Table cells never receive keyboard focus on their own
                    // when a TextField swaps in mid-double-click — without
                    // this, the field renders but typing does nothing until
                    // a second click lands directly on it.
                    .onAppear { isFocused = true }
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
