// QueryResultsPanelView.swift
// Athena — bottom-panel results grid and history for SQL run from a .sql editor tab (⌘↩).
// Swift 6, strict concurrency.

import SwiftUI

struct QueryResultsPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(connectionLabel)
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("History") {
                    if appState.requestCenter.sqlHistory.isEmpty {
                        Text("No queries yet")
                    }
                    ForEach(appState.requestCenter.sqlHistory) { entry in
                        Button(entry.sql.replacingOccurrences(of: "\n", with: " ").prefix(80) + "  (\(entry.connectionName))") {
                            Task { await appState.rerunSQL(entry) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, appState.sf(10))
            .padding(.vertical, appState.sf(4))
            Divider()
            if appState.dbQueryIsRunning {
                ProgressView("Running…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = appState.requestCenter.sqlError {
                ContentUnavailableView("Query failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let result = appState.dbQueryResult {
                if result.columns.isEmpty {
                    ContentUnavailableView("Statement executed", systemImage: "checkmark.circle",
                                           description: Text("\(result.affectedRows ?? 0) row(s) affected"))
                } else {
                    DBResultGridView(columns: result.columns, rows: result.rows,
                                     footer: "\(result.rows.count) row(s)" + (result.isTruncated ? " (truncated)" : ""))
                }
            } else {
                ContentUnavailableView("No results", systemImage: "tablecells",
                                       description: Text("Press ⌘↩ in a .sql file to run the statement at the cursor."))
            }
        }
    }

    private var connectionLabel: String {
        guard let id = appState.dbBrowserConnectionId,
              let c = appState.dbConnections.first(where: { $0.id == id }) else { return "No connection" }
        return c.name
    }
}
