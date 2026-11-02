// AppState+Profile.swift
// Athena — menu actions for exporting/importing a `.athena-profile` settings file.
// Swift 6, strict concurrency.

@preconcurrency import AppKit
import UniformTypeIdentifiers

@MainActor
extension AppState {

    func exportSettingsProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Athena.\(SettingsProfile.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: SettingsProfile.fileExtension) ?? .json]
        panel.message = "Export all Athena settings and keybindings (API keys and trust decisions are not included)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let service = SettingsProfileService(settings: settingsService)
        Task {
            do {
                try await service.export(to: url)
                statusMessage = "Exported settings profile to \(url.lastPathComponent)"
            } catch {
                statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func importSettingsProfile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: SettingsProfile.fileExtension) ?? .json]
        panel.message = "Import an Athena settings profile. Restart Athena afterwards to apply everything."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let service = SettingsProfileService(settings: settingsService)
        Task {
            do {
                let n = try await service.importProfile(from: url)
                await loadSettings()
                statusMessage = "Imported \(n) settings files. Restart Athena to apply keybindings."
            } catch {
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
