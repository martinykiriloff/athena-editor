// AppState+LanguageServers.swift
// Athena — user overrides for language-server launch commands.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    // MARK: - Persistence

    nonisolated static let languageServerOverridesKey = "languageServerOverrides"

    /// Loads persisted overrides (stored keyed by `Language.rawValue`) and
    /// hands them to the LSP manager.
    func loadLanguageServerOverrides() async {
        let stored = await settingsService.value(
            for: Self.languageServerOverridesKey, default: [String: LanguageServerOverride]())
        languageServerOverrides = Self.decodeOverrides(stored)
        await lspManager.setServerOverrides(languageServerOverrides)
    }

    nonisolated static func decodeOverrides(_ stored: [String: LanguageServerOverride]) -> [Language: LanguageServerOverride] {
        var out: [Language: LanguageServerOverride] = [:]
        for (key, value) in stored where !value.isEmpty {
            if let language = Language(rawValue: key) { out[language] = value }
        }
        return out
    }

    nonisolated static func encodeOverrides(_ overrides: [Language: LanguageServerOverride]) -> [String: LanguageServerOverride] {
        var out: [String: LanguageServerOverride] = [:]
        for (language, value) in overrides where !value.isEmpty { out[language.rawValue] = value }
        return out
    }

    // MARK: - Editing

    /// Sets (or, when empty, clears) the override for `language`, persists
    /// it, and restarts that language's server so it takes effect. Open
    /// documents of the language are re-registered with the new server.
    func setLanguageServerOverride(_ override: LanguageServerOverride, for language: Language) {
        if override.isEmpty {
            languageServerOverrides.removeValue(forKey: language)
        } else {
            languageServerOverrides[language] = override
        }
        persistSetting(Self.encodeOverrides(languageServerOverrides), for: Self.languageServerOverridesKey)
        let overrides = languageServerOverrides
        let documents = (openTabs + (secondaryGroup?.tabs ?? []))
            .filter { $0.language == language }
            .compactMap { tab in tab.fileURL.map { ($0, tab.content) } }
        let root = workspace?.rootURL
        Task {
            await self.lspManager.setServerOverrides(overrides)
            await self.lspManager.stopServer(for: language)
            guard let root, !documents.isEmpty else { return }
            try? await self.lspManager.startServer(for: language, workspaceURL: root)
            for (url, content) in documents { await self.lspManager.didOpen(fileURL: url, content: content) }
        }
    }
}
