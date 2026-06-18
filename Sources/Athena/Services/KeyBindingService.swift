// KeyBindingService.swift — persists user key binding overrides to keybindings.json.

import Foundation

// MARK: - KeyBindingService

actor KeyBindingService {

    // MARK: Types

    private struct FileEntry: Codable {
        var key: String      // VS Code format, "-" means unbound
        var command: String  // KeyAction.rawValue
    }

    // MARK: Properties

    private(set) var jsonFileURL: URL

    // MARK: Init

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Athena")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        jsonFileURL = support.appendingPathComponent("keybindings.json")
    }

    // MARK: Public API

    /// Loads defaults then applies any persisted overrides.
    func load() -> [KeyBinding] {
        var bindings = KeyBinding.vscodeDefaults

        guard let data = try? Data(contentsOf: jsonFileURL),
              let entries = try? JSONDecoder().decode([FileEntry].self, from: data)
        else { return bindings }

        for entry in entries {
            guard let action = KeyAction(rawValue: entry.command),
                  let idx = bindings.firstIndex(where: { $0.action == action })
            else { continue }

            if entry.key == "-" || entry.key.isEmpty {
                bindings[idx].combo = nil
                bindings[idx].isCustomized = true
            } else if let combo = KeyCombo.from(vsCodeString: entry.key) {
                let defaultCombo = KeyBinding.vscodeDefaults[idx].combo
                bindings[idx].combo = combo
                bindings[idx].isCustomized = (combo != defaultCombo)
            }
        }

        return bindings
    }

    /// Saves only the customized bindings (delta from defaults).
    func save(bindings: [KeyBinding]) {
        let overrides = bindings.filter(\.isCustomized).map { b in
            FileEntry(key: b.combo?.vsCodeString ?? "-", command: b.action.rawValue)
        }

        guard let data = try? JSONEncoder().encode(overrides),
              let obj  = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
        else { return }

        try? pretty.write(to: jsonFileURL)
    }

    /// Ensures the file exists on disk, writing a comment stub if not.
    func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: jsonFileURL.path) else { return }
        let stub = "[]"
        try? stub.write(to: jsonFileURL, atomically: true, encoding: .utf8)
    }
}
