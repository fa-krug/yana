import Foundation
import Security

enum KeychainService: Sendable {

    // MARK: - Core Operations

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first. The Any-matching delete also clears a copy left in the
        // iCloud-synchronizable domain by a build that still had sync, so re-saving a key migrates
        // it back to this device only.
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            // Keys never leave the device.
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Match both domains so a key written by an older, iCloud-synchronizing build still
            // loads on this device.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: key,
            // Clear both domains, including anything an older synchronizing build left behind.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - API Keys

    enum APIKeyItem: String, Sendable, CaseIterable {
        case redditClientID = "reddit_client_id"
        case redditClientSecret = "reddit_client_secret"
        case youtubeAPIKey = "youtube_api_key"
        case openaiAPIKey = "openai_api_key"
        case anthropicAPIKey = "anthropic_api_key"
        case geminiAPIKey = "gemini_api_key"
        case mistralAPIKey = "mistral_api_key"
        case qwenAPIKey = "qwen_api_key"
        case deepseekAPIKey = "deepseek_api_key"
    }

    @discardableResult
    static func saveAPIKey(_ value: String, for item: APIKeyItem) -> Bool {
        save(key: item.rawValue, value: value)
    }

    static func loadAPIKey(for item: APIKeyItem) -> String? {
        load(key: item.rawValue)
    }

    @discardableResult
    static func deleteAPIKey(for item: APIKeyItem) -> Bool {
        delete(key: item.rawValue)
    }

    // MARK: - Local-only migration

    /// Re-saves every stored API key so any copy left in the iCloud-synchronizable domain by an
    /// older build is replaced by a device-local one. Idempotent; safe to run on every launch.
    static func migrateToDeviceLocal() {
        for item in APIKeyItem.allCases {
            if let value = loadAPIKey(for: item) { saveAPIKey(value, for: item) }
        }
    }

}
