// WorkspaceTrustService.swift
// Athena — persists per-folder trust decisions via SettingsService.
// Swift 6, strict concurrency.

import Foundation

actor WorkspaceTrustService {
    static let settingsKey = "workspaceTrust"

    private let settings: SettingsService

    init(settings: SettingsService) {
        self.settings = settings
    }

    func state(for url: URL) async -> WorkspaceTrustState {
        let record: WorkspaceTrustRecord = await settings.value(for: Self.settingsKey, default: WorkspaceTrustRecord())
        return record.state(for: TrustPolicy.canonicalPath(url))
    }

    func set(_ state: WorkspaceTrustState, for url: URL) async {
        var record: WorkspaceTrustRecord = await settings.value(for: Self.settingsKey, default: WorkspaceTrustRecord())
        record.set(state, for: TrustPolicy.canonicalPath(url))
        try? await settings.setValue(record, for: Self.settingsKey)
    }
}
