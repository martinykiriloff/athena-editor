// SettingsProfile.swift
// Athena — the `.athena-profile` file format: all settings JSON files plus keybindings.
// Swift 6, strict concurrency.

import Foundation

// MARK: - ProfileJSON

/// A Sendable, Codable JSON tree so arbitrary settings files can be embedded as-is.
enum ProfileJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ProfileJSON])
    case object([String: ProfileJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ProfileJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ProfileJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - SettingsProfile

struct SettingsProfile: Codable, Sendable, Equatable {
    static let formatID = "athena-profile"
    static let currentVersion = 1
    static let fileExtension = "athena-profile"

    var format: String = SettingsProfile.formatID
    var version: Int = SettingsProfile.currentVersion
    var createdAt: Date
    /// Settings file name (without `.json`) to its contents.
    var settings: [String: ProfileJSON]
    /// Contents of `keybindings.json` (the user's overrides), if any.
    var keybindings: ProfileJSON?

    enum ProfileError: Error, LocalizedError, Equatable {
        case notAProfile
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .notAProfile:               return "This file is not an Athena settings profile."
            case .unsupportedVersion(let v): return "Profile version \(v) is newer than this version of Athena supports."
            }
        }
    }

    // MARK: Safety rules

    /// Keys that never travel in a profile: credentials, machine- or
    /// workspace-specific state, and trust decisions (a profile must never
    /// be able to grant Workspace Trust).
    static let excludedKeys: Set<String> = [
        "claudeApiKey", "lastWorkspacePath", WorkspaceTrustService.settingsKey, "update.skippedVersion"
    ]

    /// Allowed on export and import: a plain file name, not excluded, not secret-looking.
    static func isPortableKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.count <= 120,
              key.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              !key.hasPrefix("."),
              !excludedKeys.contains(key)
        else { return false }
        let lower = key.lowercased()
        return !["apikey", "token", "secret", "password"].contains { lower.contains($0) }
    }

    // MARK: Coding

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decode(_ data: Data) throws -> SettingsProfile {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let profile = try? d.decode(SettingsProfile.self, from: data),
              profile.format == formatID
        else { throw ProfileError.notAProfile }
        guard profile.version <= currentVersion else { throw ProfileError.unsupportedVersion(profile.version) }
        return profile
    }
}
