// SettingsView.swift
// Athena — application preferences window, VS Code parity.
// All controls write directly to AppState; changes take effect immediately.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self)      private var appState
    @Environment(UpdateService.self) private var updateService

    @State private var query = ""

    private var filter: SettingsFilter { SettingsFilter(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search settings", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)

            if filter.isActive {
                searchResults
            } else {
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
            }
        }
        .environment(\.settingsFilter, filter)
        .frame(width: 680, height: 560)
        // Loaded here rather than on the AI tab so its fields are filled in
        // when they first appear as search results too.
        .task {
            guard !aiLoaded else { return }
            aiLoaded = true
            apiKey      = appState.claudeAPIKey
            claudeModel = await appState.settingsService.value(for: "claudeModel",  default: "claude-opus-4-5")
        }
    }

    // MARK: - Search

    /// Every searchable setting in one form, narrowed by `filter`.
    @ViewBuilder
    private var searchResults: some View {
        if SettingsIndex.all.contains(where: { filter.matches([$0.title] + $0.labels) }) {
            let state = Bindable(appState)
            Form {
                editorSections(state: state)
                appearanceSections(state: state)
                aiSections
            }
            .formStyle(.grouped)
        } else {
            VStack(spacing: 6) {
                Text("No settings match \u{201C}\(query)\u{201D}")
                    .foregroundStyle(.secondary)
                Text("Keybindings have their own search in the Keybindings tab.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Editor Tab

    private var editorTab: some View {
        let state = Bindable(appState)
        return editorTabContent(state: state)
    }

    private func editorTabContent(state: Bindable<AppState>) -> some View {
        ScrollView {
            Form {
                editorSections(state: state)
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func editorSections(state: Bindable<AppState>) -> some View {
        // ── Font ──────────────────────────────────────────────────
        SettingsSection(SettingsIndex.font) {
            SettingRow("Font Family") {
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
            }

            SettingRow("Font Size") {
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
            }

            SettingRow("Font Ligatures") {
                Toggle("Font Ligatures", isOn: state.editorFontLigatures)
                    .onChange(of: appState.editorFontLigatures) { _, v in
                        appState.persistSetting(v, for: "editorFontLigatures")
                    }
                    .help("Enable programming ligatures (→, !=, ===, etc.)")
            }

            SettingRow("Line Height") {
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
        }

        // ── Indentation ───────────────────────────────────────────
        SettingsSection(SettingsIndex.indentation) {
            SettingRow("Tab Size") {
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
            }

            SettingRow("Insert Spaces") {
                Toggle("Insert Spaces", isOn: state.editorInsertSpaces)
                    .onChange(of: appState.editorInsertSpaces) { _, v in
                        appState.persistSetting(v, for: "editorInsertSpaces")
                    }
                    .help("Tab key inserts spaces instead of a tab character")
            }

            SettingRow("Detect Indentation") {
                Toggle("Detect Indentation", isOn: state.editorDetectIndentation)
                    .onChange(of: appState.editorDetectIndentation) { _, v in
                        appState.persistSetting(v, for: "editorDetectIndentation")
                    }
                    .help("Auto-detect tab size and insert spaces from file content")
            }

            SettingRow("Auto Indent") {
                Toggle("Auto Indent", isOn: state.editorAutoIndent)
                    .onChange(of: appState.editorAutoIndent) { _, v in
                        appState.persistSetting(v, for: "editorAutoIndent")
                    }
            }
        }

        // ── Display ───────────────────────────────────────────────
        SettingsSection(SettingsIndex.display) {
            SettingRow("Word Wrap") {
                Toggle("Word Wrap", isOn: state.editorWordWrap)
                    .onChange(of: appState.editorWordWrap) { _, v in
                        appState.persistSetting(v, for: "editorWordWrap")
                    }
            }

            SettingRow("Line Numbers") {
                Toggle("Line Numbers", isOn: state.editorLineNumbers)
                    .onChange(of: appState.editorLineNumbers) { _, v in
                        appState.persistSetting(v, for: "editorLineNumbers")
                    }
            }

            SettingRow("Render Whitespace") {
                Toggle("Render Whitespace", isOn: state.editorRenderWhitespace)
                    .onChange(of: appState.editorRenderWhitespace) { _, v in
                        appState.persistSetting(v, for: "editorRenderWhitespace")
                    }
                    .help("Show · for spaces and → for tabs")
            }

            SettingRow("Scroll Beyond Last Line") {
                Toggle("Scroll Beyond Last Line", isOn: state.editorScrollBeyondLastLine)
                    .onChange(of: appState.editorScrollBeyondLastLine) { _, v in
                        appState.persistSetting(v, for: "editorScrollBeyondLastLine")
                    }
            }
        }

        // ── Cursor ────────────────────────────────────────────────
        SettingsSection(SettingsIndex.cursor) {
            SettingRow("Cursor Style") {
                Picker("Cursor Style", selection: state.editorCursorStyle) {
                    Text("Line").tag("line")
                    Text("Block").tag("block")
                    Text("Underline").tag("underline")
            }
            .onChange(of: appState.editorCursorStyle) { _, v in
                appState.persistSetting(v, for: "editorCursorStyle")
            }
            }

            SettingRow("Cursor Blinking") {
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
        }

        // ── Files ─────────────────────────────────────────────────
        SettingsSection(SettingsIndex.files) {
            SettingRow("Format on Save") {
                Toggle("Format on Save", isOn: state.editorFormatOnSave)
                    .onChange(of: appState.editorFormatOnSave) { _, v in
                        appState.persistSetting(v, for: "editorFormatOnSave")
                    }
            }
        }
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        let state = Bindable(appState)
        return appearanceTabContent(state: state)
    }

    private func appearanceTabContent(state: Bindable<AppState>) -> some View {
        Form {
            appearanceSections(state: state)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func appearanceSections(state: Bindable<AppState>) -> some View {
        SettingsSection(SettingsIndex.theme) {
            SettingRow("Color Theme") {
                Picker("Color Theme", selection: state.currentTheme) {
                    ForEach(appState.allThemes, id: \.id) { t in
                        Text(t.name).tag(t)
                    }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: appState.currentTheme) { _, v in
                appState.persistSetting(v.id, for: "theme")
            }
            }

            SettingRow("Import VS Code Theme") {
                Button("Import VS Code Theme…") {
                    importVSCodeTheme()
            }
            .help("Pick a VS Code theme JSON file (colors + tokenColors) to add it to the list above")
            }
        }

        SettingsSection(SettingsIndex.minimap) {
            SettingRow("Enable Minimap") {
                Toggle("Enable Minimap", isOn: state.editorMinimapEnabled)
                    .onChange(of: appState.editorMinimapEnabled) { _, v in
                        appState.persistSetting(v, for: "editorMinimapEnabled")
                    }
                    .help("Show a scaled-down overview of the file to the right of the editor")
            }
        }
    }

    /// `NSOpenPanel` file-picker filtered to JSON, matching
    /// `WelcomeView.cloneRepository()`'s folder-picker pattern — runs
    /// modally (this is a Settings sheet, already modal-ish in feel) then
    /// hands the chosen file to `AppState.importVSCodeTheme(from:)`.
    private func importVSCodeTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.title = "Import VS Code Theme"
        panel.message = "Choose a VS Code theme JSON file"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await appState.importVSCodeTheme(from: url)
        }
    }

    // MARK: - AI Tab

    @State private var apiKey: String = ""
    @State private var showApiKey: Bool = false
    @State private var claudeModel: String = "claude-opus-4-5"
    @State private var aiLoaded: Bool = false
    @State private var ollamaModels: [String] = []
    @State private var isFetchingOllamaModels: Bool = false

    private let availableModels = [
        "claude-opus-4-8",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
    ]

    private var aiTab: some View {
        Form {
            aiSections
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var aiSections: some View {
        SettingsSection(SettingsIndex.api) {
            SettingRow("Claude API Key") {
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
            }

            SettingRow("Default Model") {
                Picker("Default Model", selection: $claudeModel) {
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: claudeModel) { _, v in
                appState.persistSetting(v, for: "claudeModel")
            }
            }
        }

        SettingsSection(SettingsIndex.ghostText) {
            SettingRow("Provider") {
                Picker("Provider", selection: Bindable(appState).ghostTextProvider) {
                    ForEach(GhostTextProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
            }
            .onChange(of: appState.ghostTextProvider) { _, v in
                appState.persistSetting(v.rawValue, for: "ghostTextProvider")
            }
            }

            // Provider-specific rows appear together: an endpoint without
            // its model is no use on its own.
            if appState.ghostTextProvider == .ollama {
                HStack {
                    Text("Endpoint")
                    Spacer()
                    TextField("http://127.0.0.1:11434", text: Bindable(appState).ollamaEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: appState.ollamaEndpoint) { _, v in
                            appState.persistSetting(v, for: "ollamaEndpoint")
                            ollamaModels = []  // stale for the old endpoint
                        }
                }
                HStack {
                    Text("Model")
                    Spacer()
                    if ollamaModels.isEmpty {
                        TextField("qwen2.5-coder:7b", text: Bindable(appState).ollamaModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onChange(of: appState.ollamaModel) { _, v in
                                appState.persistSetting(v, for: "ollamaModel")
                            }
                    } else {
                        Picker("", selection: Bindable(appState).ollamaModel) {
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: appState.ollamaModel) { _, v in
                            appState.persistSetting(v, for: "ollamaModel")
                        }
                    }
                    Button {
                        Task {
                            isFetchingOllamaModels = true
                            ollamaModels = await appState.fetchOllamaModels()
                            isFetchingOllamaModels = false
                        }
                    } label: {
                        if isFetchingOllamaModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Fetch installed models from Ollama")
                }
                Text("Any model available in Ollama works. Run `ollama pull <model>` to install.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.ghostTextProvider == .openAICompatible {
                HStack {
                    Text("Endpoint")
                    Spacer()
                    TextField("http://127.0.0.1:1234/v1", text: Bindable(appState).localOAIEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: appState.localOAIEndpoint) { _, v in
                            appState.persistSetting(v, for: "localOAIEndpoint")
                        }
                }
                HStack {
                    Text("Model")
                    Spacer()
                    TextField("model id", text: Bindable(appState).localOAIModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: appState.localOAIModel) { _, v in
                            appState.persistSetting(v, for: "localOAIModel")
                        }
                }
                HStack {
                    Text("API Key")
                    Spacer()
                    TextField("optional", text: Bindable(appState).localOAIAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: appState.localOAIAPIKey) { _, v in
                            appState.persistSetting(v, for: "localOAIAPIKey")
                        }
                }
                Text("Any server speaking the OpenAI /v1/completions API works — LM Studio, llama.cpp's `server`, vLLM, etc. Include the /v1 prefix in Endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.ghostTextProvider != .none {
                HStack {
                    Text("Debounce")
                    Spacer()
                    Stepper(
                        "\(appState.ghostTextDebounceMs) ms",
                        value: Bindable(appState).ghostTextDebounceMs,
                        in: 100...3000, step: 100
                    )
                    .frame(width: 160)
                    .onChange(of: appState.ghostTextDebounceMs) { _, v in
                        appState.persistSetting(v, for: "ghostTextDebounceMs")
                    }
                }
            }

            if appState.ghostTextProvider == .ollama || appState.ghostTextProvider == .openAICompatible {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Stepper(
                        String(format: "%.1f", appState.ghostTextTemperature),
                        value: Bindable(appState).ghostTextTemperature,
                        in: 0...1, step: 0.1
                    )
                    .frame(width: 160)
                    .onChange(of: appState.ghostTextTemperature) { _, v in
                        appState.persistSetting(v, for: "ghostTextTemperature")
                    }
                }
                HStack {
                    Text("Max Tokens")
                    Spacer()
                    Stepper(
                        "\(appState.ghostTextMaxTokens)",
                        value: Bindable(appState).ghostTextMaxTokens,
                        in: 16...512, step: 16
                    )
                    .frame(width: 160)
                    .onChange(of: appState.ghostTextMaxTokens) { _, v in
                        appState.persistSetting(v, for: "ghostTextMaxTokens")
                    }
                }
                Toggle("Include code context", isOn: Bindable(appState).includeGhostTextContext)
                    .onChange(of: appState.includeGhostTextContext) { _, v in
                        appState.persistSetting(v, for: "includeGhostTextContext")
                    }
                Text("Prepends the file's imports and the enclosing function/class to every request — off if it hurts latency more than it helps quality.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

        case .available(let release):
            Label("Athena \(release.version) is available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
            Button("Install and Restart") {
                Task { await updateService.install { await appState.saveAllTabs() } }
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

// MARK: - Search filter

/// The Settings search query. Rows and sections read it from the
/// environment and hide themselves when they don't match.
struct SettingsFilter {
    var query: String = ""

    var isActive: Bool { !trimmed.isEmpty }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    func matches(_ texts: [String]) -> Bool {
        !isActive || texts.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

// A plain key rather than `@Entry`: the Command Line Tools toolchain ships
// without the SwiftUI macro plugin.
private struct SettingsFilterKey: EnvironmentKey {
    static let defaultValue = SettingsFilter()
}

extension EnvironmentValues {
    var settingsFilter: SettingsFilter {
        get { self[SettingsFilterKey.self] }
        set { self[SettingsFilterKey.self] = newValue }
    }
}

/// A section's title and the labels of the rows in it. A section shows when
/// its title or any row label matches; a title match shows all its rows.
/// Every `SettingRow` label must be listed in its section's entry here.
struct SettingsIndexEntry {
    let title: String
    let labels: [String]
}

enum SettingsIndex {
    static let font = SettingsIndexEntry(title: "Font", labels: ["Font Family", "Font Size", "Font Ligatures", "Line Height"])
    static let indentation = SettingsIndexEntry(title: "Indentation", labels: ["Tab Size", "Insert Spaces", "Detect Indentation", "Auto Indent"])
    static let display = SettingsIndexEntry(title: "Display", labels: ["Word Wrap", "Line Numbers", "Render Whitespace", "Scroll Beyond Last Line"])
    static let cursor = SettingsIndexEntry(title: "Cursor", labels: ["Cursor Style", "Cursor Blinking"])
    static let files = SettingsIndexEntry(title: "Files", labels: ["Format on Save"])
    static let theme = SettingsIndexEntry(title: "Theme", labels: ["Color Theme", "Import VS Code Theme"])
    static let minimap = SettingsIndexEntry(title: "Minimap", labels: ["Enable Minimap"])
    static let api = SettingsIndexEntry(title: "API", labels: ["Claude API Key", "Default Model"])
    static let ghostText = SettingsIndexEntry(title: "Predictive Completion (Ghost Text)", labels: ["Provider"])

    static let all = [font, indentation, display, cursor, files, theme, minimap, api, ghostText]
}

private struct SettingsSection<Content: View>: View {
    @Environment(\.settingsFilter) private var filter
    let entry: SettingsIndexEntry
    @ViewBuilder let content: Content

    init(_ entry: SettingsIndexEntry, @ViewBuilder content: () -> Content) {
        self.entry = entry
        self.content = content()
    }

    var body: some View {
        if filter.matches([entry.title]) {
            Section(entry.title) { content }
                .environment(\.settingsFilter, SettingsFilter())
        } else if filter.matches(entry.labels) {
            Section(entry.title) { content }
        }
    }
}

private struct SettingRow<Content: View>: View {
    @Environment(\.settingsFilter) private var filter
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        if filter.matches([label]) { content }
    }
}
