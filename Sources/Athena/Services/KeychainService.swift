//  KeychainService.swift
//  Stores secrets (Claude API key, connection passwords) in the macOS Keychain.
//  Swift 6, strict concurrency.

import Foundation
import Security

/// Thin actor wrapper over the Security framework's generic-password items.
/// Every secret shares one service identifier and is addressed by `account`.
actor KeychainService {

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    private let service = "com.martinkirilov.athena"

    // MARK: - Accounts

    static let claudeAPIKeyAccount = "claudeApiKey"
    static func dbPassword(_ id: UUID)   -> String { "db.\(id.uuidString)" }
    static func sfccPassword(_ id: UUID) -> String { "sfcc.\(id.uuidString)" }

    // MARK: - Read / Write / Delete

    /// Stores `value` for `account`, overwriting any existing item.
    /// An empty value removes the item instead, so callers can persist a
    /// cleared field without special-casing.
    func set(_ value: String, account: String) throws {
        guard !value.isEmpty else { try delete(account: account); return }

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String]      = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Returns the stored secret for `account`, or `nil` if absent.
    func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the secret for `account`. A missing item is not an error.
    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
