// LanguageServerOverrideRow.swift
// Athena — Settings row for one language's server path/arguments override.
// Swift 6, strict concurrency.

import SwiftUI

struct LanguageServerOverrideRow: View {
    @Environment(AppState.self) private var appState
    let language: Language

    @State private var path = ""
    @State private var arguments = ""
    @State private var loaded = false

    private var placeholder: String {
        LanguageServerCatalog.spec(for: language)?.executable ?? "sourcekit-lsp"
    }

    var body: some View {
        HStack {
            Text("\(language.displayName) Server")
            Spacer()
            TextField(placeholder, text: $path)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
                .help("Executable path or command name. Leave empty to auto-detect.")
            TextField("args (default)", text: $arguments)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .help("Space-separated arguments replacing the defaults, e.g. --stdio.")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let current = appState.languageServerOverrides[language] ?? LanguageServerOverride()
            path = current.path
            arguments = current.arguments
        }
        // Committing restarts the language server, so it happens on Return
        // or when the Settings tab goes away, never per keystroke.
        .onSubmit { commit() }
        .onDisappear { commit() }
    }

    private func commit() {
        guard loaded else { return }
        let value = LanguageServerOverride(path: path, arguments: arguments)
        guard appState.languageServerOverrides[language] ?? LanguageServerOverride() != value else { return }
        appState.setLanguageServerOverride(value, for: language)
    }
}
