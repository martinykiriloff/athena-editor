// DBConnectionsView.swift — Database connection manager sidebar panel.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - DBConnectionsView

struct DBConnectionsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddSheet = false
    @State private var editingConnection: DBConnection? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if appState.dbConnections.isEmpty {
                emptyState
            } else {
                connectionList
            }
        }
        .sheet(isPresented: $showAddSheet) {
            DBConnectionFormView(connection: nil) { saved in
                appState.dbConnections.append(saved)
                persistConnections()
            }
        }
        .sheet(item: $editingConnection) { conn in
            DBConnectionFormView(connection: conn) { updated in
                if let idx = appState.dbConnections.firstIndex(where: { $0.id == updated.id }) {
                    appState.dbConnections[idx] = updated
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
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: appState.sf(13)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add Connection")
            .padding(.trailing, 8)
        }
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: appState.sf(32)))
                .foregroundStyle(.tertiary)
            Text("No connections")
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(.secondary)
            Button("Add Connection") { showAddSheet = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionList: some View {
        // @Bindable lets us derive per-element bindings from @Observable AppState.
        @Bindable var state = appState
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach($state.dbConnections) { $conn in
                    DBConnectionRow(connection: $conn, onEdit: {
                        editingConnection = conn
                    }, onDelete: {
                        let removedID = conn.id
                        appState.dbConnections.removeAll { $0.id == removedID }
                        Task { try? await appState.keychainService.delete(account: KeychainService.dbPassword(removedID)) }
                        persistConnections()
                    }, onToggle: {
                        conn.isConnected.toggle()
                        persistConnections()
                    })
                    Divider()
                }
            }
        }
    }

    // MARK: Persistence

    private func loadConnections() async {
        var decoded = await appState.settingsService.value(
            for: "dbConnections",
            default: [DBConnection]()
        )
        var didMigrate = false
        for i in decoded.indices {
            let account = KeychainService.dbPassword(decoded[i].id)
            if let pw = await appState.keychainService.get(account: account), !pw.isEmpty {
                decoded[i].password = pw
            } else if !decoded[i].password.isEmpty {
                // Legacy plaintext password from an older settings file — move it to the Keychain.
                try? await appState.keychainService.set(decoded[i].password, account: account)
                didMigrate = true
            }
        }
        appState.dbConnections = decoded
        if didMigrate { persistConnections() }  // rewrites the JSON without passwords
    }

    private func persistConnections() {
        let snapshot = appState.dbConnections
        Task {
            for conn in snapshot {
                try? await appState.keychainService.set(conn.password, account: KeychainService.dbPassword(conn.id))
            }
            try? await appState.settingsService.setValue(snapshot, for: "dbConnections")
        }
    }
}

// MARK: - DBConnectionRow

private struct DBConnectionRow: View {
    @Binding var connection: DBConnection
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void
    @Environment(AppState.self) private var appState

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(connection.isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)

            // Type badge
            Text(connection.type.rawValue.prefix(2).uppercased())
                .font(.system(size: appState.sf(9), weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(dbColor(connection.type).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 3))

            // Name + host
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.system(size: appState.sf(12), weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(connection.host):\(connection.port)")
                    .font(.system(size: appState.sf(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Action buttons (visible on hover)
            if isHovered {
                HStack(spacing: 2) {
                    IconButton("pencil", help: "Edit", action: onEdit)
                    IconButton(
                        connection.isConnected ? "stop.fill" : "bolt.fill",
                        help: connection.isConnected ? "Disconnect" : "Connect",
                        action: onToggle
                    )
                    IconButton("trash", help: "Delete", action: onDelete)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func dbColor(_ type: DBType) -> Color {
        switch type {
        case .postgresql: return Color(red: 0.20, green: 0.40, blue: 0.57)
        case .mongodb:    return Color(red: 0.30, green: 0.70, blue: 0.24)
        case .mysql:      return Color(red: 0.00, green: 0.46, blue: 0.56)
        case .oracle:     return Color(red: 0.97, green: 0.00, blue: 0.00)
        case .mariadb:    return Color(red: 0.75, green: 0.46, blue: 0.35)
        }
    }
}

// MARK: - DBConnectionFormView

struct DBConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss

    // Pre-populate with an existing connection for edits; nil for new.
    private let original: DBConnection?
    private let onSave: (DBConnection) -> Void

    @State private var name: String
    @State private var type: DBType
    @State private var host: String
    @State private var port: String
    @State private var database: String
    @State private var username: String
    @State private var password: String
    @State private var showPassword = false

    init(connection: DBConnection?, onSave: @escaping (DBConnection) -> Void) {
        self.original = connection
        self.onSave   = onSave
        _name     = State(initialValue: connection?.name     ?? "")
        _type     = State(initialValue: connection?.type     ?? .postgresql)
        _host     = State(initialValue: connection?.host     ?? "localhost")
        _port     = State(initialValue: connection.map { String($0.port) } ?? "5432")
        _database = State(initialValue: connection?.database ?? "")
        _username = State(initialValue: connection?.username ?? "")
        _password = State(initialValue: connection?.password ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(original == nil ? "New Connection" : "Edit Connection")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            Divider()

            Form {
                Section("General") {
                    TextField("Connection Name", text: $name)

                    Picker("Type", selection: $type) {
                        ForEach(DBType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .onChange(of: type) { _, newType in
                        if port == String(type.defaultPort) || port.isEmpty {
                            port = String(newType.defaultPort)
                        }
                    }
                }

                Section("Server") {
                    TextField("Host", text: $host)
                    TextField("Port", text: $port)
                        .onReceive(port.publisher.collect()) { chars in
                            let filtered = String(chars.filter(\.isNumber))
                            if filtered != port { port = filtered }
                        }
                    TextField("Database", text: $database)
                }

                Section("Authentication") {
                    TextField("Username", text: $username)
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        var conn = original ?? DBConnection(name: name, type: type)
        conn.name     = name.trimmingCharacters(in: .whitespaces)
        conn.type     = type
        conn.host     = host.trimmingCharacters(in: .whitespaces)
        conn.port     = Int(port) ?? type.defaultPort
        conn.database = database.trimmingCharacters(in: .whitespaces)
        conn.username = username.trimmingCharacters(in: .whitespaces)
        conn.password = password
        onSave(conn)
        dismiss()
    }
}

// MARK: - IconButton helper

private struct IconButton: View {
    let name: String
    let help: String
    let action: () -> Void
    @Environment(AppState.self) private var appState

    init(_ name: String, help: String, action: @escaping () -> Void) {
        self.name = name; self.help = help; self.action = action
    }

    var body: some View {
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
