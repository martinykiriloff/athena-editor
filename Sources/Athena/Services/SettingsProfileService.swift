// SettingsProfileService.swift
// Athena — exports and imports all settings + keybindings as one `.athena-profile` file.
// Swift 6, strict concurrency.
//
// Local files only. Cloud sync would need a server, which Athena deliberately does not have.

import Foundation

actor SettingsProfileService {

    private let settings: SettingsService
    private let keybindingsURL: URL

    init(settings: SettingsService, keybindingsURL: URL? = nil) {
        self.settings = settings
        self.keybindingsURL = keybindingsURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Athena/keybindings.json")
    }

    // MARK: - Export

    func makeProfile(now: Date = .now) async -> SettingsProfile {
        var files: [String: ProfileJSON] = [:]
        for key in await settings.allKeys() where SettingsProfile.isPortableKey(key) {
            guard let data = await settings.rawData(for: key),
                  let value = try? JSONDecoder().decode(ProfileJSON.self, from: data) else { continue }
            files[key] = value
        }
        var keybindings: ProfileJSON?
        if let data = try? Data(contentsOf: keybindingsURL) {
            keybindings = try? JSONDecoder().decode(ProfileJSON.self, from: data)
        }
        return SettingsProfile(createdAt: now, settings: files, keybindings: keybindings)
    }

    func export(to url: URL) async throws {
        let data = try SettingsProfile.encoder().encode(await makeProfile())
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Import

    /// Applies the profile and returns how many settings files were written.
    /// Unsafe or non-portable keys are skipped, never written.
    @discardableResult
    func importProfile(from url: URL) async throws -> Int {
        let profile = try SettingsProfile.decode(Data(contentsOf: url))
        return try await apply(profile)
    }

    @discardableResult
    func apply(_ profile: SettingsProfile) async throws -> Int {
        var written = 0
        let encoder = JSONEncoder()
        for (key, value) in profile.settings where SettingsProfile.isPortableKey(key) {
            try await settings.setRawData(try encoder.encode(value), for: key)
            written += 1
        }
        if let keybindings = profile.keybindings {
            try FileManager.default.createDirectory(
                at: keybindingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(keybindings).write(to: keybindingsURL, options: .atomic)
        }
        return written
    }
}
