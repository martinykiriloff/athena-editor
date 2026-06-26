// SettingsView.swift
// Athena — application preferences window, VS Code parity.
// All controls write directly to AppState; changes take effect immediately.

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self)      private var appState
    @Environment(UpdateService.self) private var updateService

    var body: some View {
        TabView {
            editorTab
                .tabItem { Label("Editor", systemImage: "doc.text") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            aiTab
                .tabItem { Label("AI", systemImage: "sparkles") }
            KeybindingsView()
                .tabItem { Label("Keybindings", systemImage: "keyboard") }
            updatesTab
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 680, height: 560)
    }

    // MARK: - Editor Tab

    private var editorTab: some View {
        let state = Bindable(appState)
        return editorTabContent(state: state)
    }

    private func editorTabContent(state: Bindable<AppState>) -> some View {
        ScrollView {
            Form {
                // ── Font ──────────────────────────────────────────────────
                Section("Font") {
                    HStack {
                        Text("Font Family")
                        Spacer()
                        TextField("e.g. JetBrains Mono", text: state.editorFontFamily)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onChange(of: appState.editorFontFamily) { _, v in
                                appState.persistSetting(v, for: "editorFontFamily")
                            }
                    }

                    HStack {
                        Text("Font Size")
                        Spacer()
                        Stepper(
                            value: state.editorFontSize,
                            in: 8...32, step: 1,
                            label: {
                                Text("\(Int(appState.editorFontSize)) pt")
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 36, alignment: .trailing)
                            }
                        )
                        .onChange(of: appState.editorFontSize) { _, v in
                            appState.persistSetting(v, for: "editorFontSize")
                        }
                        Slider(value: state.editorFontSize, in: 8...32, step: 1)
                            .frame(width: 140)
                            .onChange(of: appState.editorFontSize) { _, v in
                                appState.persistSetting(v, for: "editorFontSize")
                            }
                    }

                    Toggle("Font Ligatures", isOn: state.editorFontLigatures)
                        .onChange(of: appState.editorFontLigatures) { _, v in
                            appState.persistSetting(v, for: "editorFontLigatures")
                        }
                        .help("Enable programming ligatures (→, !=, ===, etc.)")

                    HStack {
                        Text("Line Height")
                        Spacer()
                        Text(String(format: "%.1f×", appState.editorLineHeight))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                        Slider(value: state.editorLineHeight, in: 1.0...3.0, step: 0.1)
                            .frame(width: 140)
                            .onChange(of: appState.editorLineHeight) { _, v in
                                appState.persistSetting(v, for: "editorLineHeight")
                            }
                    }
                }

                // ── Indentation ───────────────────────────────────────────
                Section("Indentation") {
                    HStack {
                        Text("Tab Size")
                        Spacer()
                        Picker("", selection: state.editorTabSize) {
                            Text("1").tag(1)
                            Text("2").tag(2)
                            Text("4").tag(4)
                            Text("8").tag(8)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                        .labelsHidden()
                        .onChange(of: appState.editorTabSize) { _, v in
                            appState.persistSetting(v, for: "editorTabSize")
                        }
                    }

                    Toggle("Insert Spaces", isOn: state.editorInsertSpaces)
                        .onChange(of: appState.editorInsertSpaces) { _, v in
                            appState.persistSetting(v, for: "editorInsertSpaces")
                        }
                        .help("Tab key inserts spaces instead of a tab character")

                    Toggle("Detect Indentation", isOn: state.editorDetectIndentation)
                        .onChange(of: appState.editorDetectIndentation) { _, v in
                            appState.persistSetting(v, for: "editorDetectIndentation")
                        }
                        .help("Auto-detect tab size and insert spaces from file content")

                    Toggle("Auto Indent", isOn: state.editorAutoIndent)
                        .onChange(of: appState.editorAutoIndent) { _, v in
                            appState.persistSetting(v, for: "editorAutoIndent")
                        }
                }

                // ── Display ───────────────────────────────────────────────
                Section("Display") {
                    Toggle("Word Wrap", isOn: state.editorWordWrap)
                        .onChange(of: appState.editorWordWrap) { _, v in
                            appState.persistSetting(v, for: "editorWordWrap")
                        }

                    Toggle("Line Numbers", isOn: state.editorLineNumbers)
                        .onChange(of: appState.editorLineNumbers) { _, v in
                            appState.persistSetting(v, for: "editorLineNumbers")
                        }

                    Toggle("Render Whitespace", isOn: state.editorRenderWhitespace)
                        .onChange(of: appState.editorRenderWhitespace) { _, v in
                            appState.persistSetting(v, for: "editorRenderWhitespace")
                        }
                        .help("Show · for spaces and → for tabs")

                    Toggle("Scroll Beyond Last Line", isOn: state.editorScrollBeyondLastLine)
                        .onChange(of: appState.editorScrollBeyondLastLine) { _, v in
                            appState.persistSetting(v, for: "editorScrollBeyondLastLine")
                        }
                }

                // ── Cursor ────────────────────────────────────────────────
                Section("Cursor") {
                    Picker("Cursor Style", selection: state.editorCursorStyle) {
                        Text("Line").tag("line")
                        Text("Block").tag("block")
                        Text("Underline").tag("underline")
                    }
                    .onChange(of: appState.editorCursorStyle) { _, v in
                        appState.persistSetting(v, for: "editorCursorStyle")
                    }

                    Picker("Cursor Blinking", selection: state.editorCursorBlink) {
                        Text("Blink").tag("blink")
                        Text("Smooth").tag("smooth")
                        Text("Phase").tag("phase")
                        Text("Solid").tag("solid")
                    }
                    .onChange(of: appState.editorCursorBlink) { _, v in
                        appState.persistSetting(v, for: "editorCursorBlink")
                    }
                }

                // ── Files ─────────────────────────────────────────────────
                Section("Files") {
                    Toggle("Format on Save", isOn: state.editorFormatOnSave)
                        .onChange(of: appState.editorFormatOnSave) { _, v in
                            appState.persistSetting(v, for: "editorFormatOnSave")
                        }
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        let state = Bindable(appState)
        return appearanceTabContent(state: state)
    }

    private func appearanceTabContent(state: Bindable<AppState>) -> some View {
        Form {
            Section("Theme") {
                Picker("Color Theme", selection: state.currentTheme) {
                    ForEach(EditorTheme.all, id: \.id) { t in
                        Text(t.name).tag(t)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: appState.currentTheme) { _, v in
                    appState.persistSetting(v.id, for: "theme")
                }
            }

            Section("Minimap") {
                Toggle("Enable Minimap", isOn: state.editorMinimapEnabled)
                    .onChange(of: appState.editorMinimapEnabled) { _, v in
                        appState.persistSetting(v, for: "editorMinimapEnabled")
                    }
                    .help("Show a scaled-down overview of the file to the right of the editor")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - AI Tab

    @State private var apiKey: String = ""
    @State private var showApiKey: Bool = false
    @State private var claudeModel: String = "claude-opus-4-5"
    @State private var aiLoaded: Bool = false

    private let availableModels = [
        "claude-opus-4-8",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
    ]

    private var aiTab: some View {
        Form {
            Section("API") {
                HStack {
                    Text("Claude API Key")
                    Spacer()
                    Group {
                        if showApiKey {
                            TextField("sk-ant-…", text: $apiKey)
                        } else {
                            SecureField("sk-ant-…", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onChange(of: apiKey) { _, v in
                        appState.setClaudeAPIKey(v)
                    }
                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Picker("Default Model", selection: $claudeModel) {
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: claudeModel) { _, v in
                    appState.persistSetting(v, for: "claudeModel")
                }
            }

            Section("Predictive Completion (Ghost Text)") {
                Picker("Provider", selection: Bindable(appState).ghostTextProvider) {
                    ForEach(GhostTextProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: appState.ghostTextProvider) { _, v in
                    appState.persistSetting(v.rawValue, for: "ghostTextProvider")
                }

                if appState.ghostTextProvider == .ollama {
                    HStack {
                        Text("Endpoint")
                        Spacer()
                        TextField("http://localhost:11434", text: Bindable(appState).ollamaEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onChange(of: appState.ollamaEndpoint) { _, v in
                                appState.persistSetting(v, for: "ollamaEndpoint")
                            }
                    }
                    HStack {
                        Text("Model")
                        Spacer()
                        TextField("qwen2.5-coder:7b", text: Bindable(appState).ollamaModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onChange(of: appState.ollamaModel) { _, v in
                                appState.persistSetting(v, for: "ollamaModel")
                            }
                    }
                    Text("Any model available in Ollama works. Run `ollama pull <model>` to install.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            guard !aiLoaded else { return }
            aiLoaded = true
            apiKey      = appState.claudeAPIKey
            claudeModel = await appState.settingsService.value(for: "claudeModel",  default: "claude-opus-4-5")
        }
    }

    // MARK: - Updates Tab

    private var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var updatesTab: some View {
        Form {
            Section("Version") {
                HStack {
                    Text("Installed Version")
                    Spacer()
                    Text(installedVersion).foregroundStyle(.secondary)
                }
                if let checked = updateService.lastChecked {
                    HStack {
                        Text("Last Checked")
                        Spacer()
                        Text(checked, style: .relative).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Check for Updates") {
                updatesContent
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var updatesContent: some View {
        switch updateService.state {
        case .idle:
            Button("Check for Updates") {
                Task { await updateService.checkForUpdates() }
            }

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            }

        case .upToDate:
            Label("Athena is up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button("Check Again") {
                Task { await updateService.checkForUpdates() }
            }

        case .available(let version, _):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Update \(version) found — downloading…").foregroundStyle(.secondary)
            }

        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                let label = updateService.pendingVersion.map { "Downloading v\($0)…" } ?? "Downloading update…"
                Text(label).foregroundStyle(.secondary)
            }

        case .readyToInstall:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Saving files and restarting…").foregroundStyle(.secondary)
            }

        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 11))
            Button("Try Again") {
                Task { await updateService.checkForUpdates() }
            }
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        Form {
            Section {
                HStack {
                    Text("Athena").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(installedVersion).foregroundStyle(.secondary)
                }
                Text("Native Swift 6 code editor")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
    }
}
