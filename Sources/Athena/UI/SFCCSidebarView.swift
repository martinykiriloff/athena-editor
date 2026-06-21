// SFCCSidebarView.swift
// Athena — SFCC sandbox connection manager (sidebar panel).
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - SFCCSidebarView

struct SFCCSidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddSheet   = false
    @State private var editingConn: SFCCConnection? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if appState.sfccConnections.isEmpty {
                emptyState
            } else {
                connectionList
            }
        }
        .sheet(isPresented: $showAddSheet) {
            SFCCConnectionFormView(connection: nil) { saved in
                appState.sfccConnections.append(saved)
                persistConnections()
            }
        }
        .sheet(item: $editingConn) { conn in
            SFCCConnectionFormView(connection: conn) { updated in
                if let idx = appState.sfccConnections.firstIndex(where: { $0.id == updated.id }) {
                    appState.sfccConnections[idx] = updated
                    persistConnections()
                }
            }
        }
        .task { await loadConnections() }
    }

    // MARK: Subviews

    private var toolbar: some View {
        HStack {
            Spacer()
            Button { showAddSheet = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: appState.sf(13)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add Sandbox")
            .padding(.trailing, 8)
        }
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud")
                .font(.system(size: appState.sf(32)))
                .foregroundStyle(.tertiary)
            Text("No sandboxes")
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(.secondary)
            Button("Add Sandbox") { showAddSheet = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionList: some View {
        @Bindable var state = appState
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach($state.sfccConnections) { $conn in
                    SFCCConnectionRow(
                        connection: $conn,
                        onEdit:   { editingConn = conn },
                        onDelete: {
                            appState.sfccConnections.removeAll { $0.id == conn.id }
                            persistConnections()
                        },
                        onToggle: {
                            let targetID = conn.id
                            let newActive = !conn.isActive
                            for i in appState.sfccConnections.indices {
                                appState.sfccConnections[i].isActive =
                                    appState.sfccConnections[i].id == targetID ? newActive : false
                            }
                            persistConnections()
                        }
                    )
                    Divider()
                }
            }
        }
    }

    // MARK: Persistence

    private func loadConnections() async {
        let decoded = await appState.settingsService.value(
            for: "sfccConnections",
            default: [SFCCConnection]()
        )
        appState.sfccConnections = decoded
    }

    private func persistConnections() {
        let snapshot = appState.sfccConnections
        Task { try? await appState.settingsService.setValue(snapshot, for: "sfccConnections") }
    }
}

// MARK: - SFCCConnectionRow

private struct SFCCConnectionRow: View {
    @Binding var connection: SFCCConnection
    let onEdit:   () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void

    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(connection.isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .font(.system(size: appState.sf(12), weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(connection.hostname)
                    .font(.system(size: appState.sf(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered {
                HStack(spacing: 2) {
                    sfccIconButton("pencil",      help: "Edit",                         action: onEdit)
                    sfccIconButton(connection.isActive ? "stop.fill" : "bolt.fill",
                                  help: connection.isActive ? "Deactivate" : "Activate", action: onToggle)
                    sfccIconButton("trash",       help: "Delete",                       action: onDelete)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private func sfccIconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - SFCCConnectionFormView

struct SFCCConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss
    private let original: SFCCConnection?
    private let onSave: (SFCCConnection) -> Void

    @State private var name: String
    @State private var hostname: String
    @State private var username: String
    @State private var password: String
    @State private var codeVersion: String
    @State private var cartridgesPath: String
    @State private var showPassword = false

    init(connection: SFCCConnection?, onSave: @escaping (SFCCConnection) -> Void) {
        self.original = connection
        self.onSave   = onSave
        _name           = State(initialValue: connection?.name           ?? "")
        _hostname       = State(initialValue: connection?.hostname       ?? "")
        _username       = State(initialValue: connection?.username       ?? "")
        _password       = State(initialValue: connection?.password       ?? "")
        _codeVersion    = State(initialValue: connection?.codeVersion    ?? "version1")
        _cartridgesPath = State(initialValue: connection?.cartridgesPath ?? "cartridges")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(original == nil ? "New Sandbox" : "Edit Sandbox")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save")   { save()    }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            Divider()

            Form {
                Section("General") {
                    TextField("Connection Name", text: $name)
                }
                Section("Server") {
                    TextField("Hostname  (e.g. dev01-abc.demandware.net)", text: $hostname)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Deployment") {
                    TextField("Code Version  (e.g. version1)", text: $codeVersion)
                        .autocorrectionDisabled()
                    TextField("Cartridges path  (relative to workspace root)", text: $cartridgesPath)
                        .autocorrectionDisabled()
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        var c = original ?? SFCCConnection(name: name, hostname: hostname)
        c.name           = name.trimmingCharacters(in: .whitespaces)
        c.hostname       = hostname.trimmingCharacters(in: .whitespaces)
        c.username       = username.trimmingCharacters(in: .whitespaces)
        c.password       = password
        c.codeVersion    = codeVersion.trimmingCharacters(in: .whitespaces)
        c.cartridgesPath = cartridgesPath.trimmingCharacters(in: .whitespaces)
        onSave(c)
        dismiss()
    }
}
