import Foundation

actor SettingsService {

    // MARK: - Storage

    private let settingsDirectory: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Athena/settings")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Athena/settings")

        settingsDirectory = base

        try? FileManager.default.createDirectory(
            at: settingsDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - File URL

    private func fileURL(for key: String) -> URL {
        settingsDirectory.appendingPathComponent(key + ".json")
    }

    // MARK: - Generic Read / Write

    func value<T: Codable & Sendable>(for key: String, default defaultValue: T) async -> T {
        let url = fileURL(for: key)
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(T.self, from: data)
        else {
            return defaultValue
        }
        return decoded
    }

    func setValue<T: Codable & Sendable>(_ value: T, for key: String) async throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL(for: key), options: .atomic)
    }

    // MARK: - Reset

    func reset(key: String) async {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    // MARK: - Convenience Properties

    func theme() async -> String {
        await value(for: "theme", default: "darcula")
    }

    func fontSize() async -> Double {
        await value(for: "fontSize", default: 14.0)
    }

    func claudeApiKey() async -> String {
        await value(for: "claudeApiKey", default: "")
    }

    func tabSize() async -> Int {
        await value(for: "tabSize", default: 4)
    }
}
