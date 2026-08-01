import Foundation
import Security

enum KeychainService: Sendable {

    // MARK: - Core Operations

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first (Any-matching delete clears both local
        // and synchronizable copies to avoid duplicates across domains).
        delete(key: key)


        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
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
            // Match both local and synchronizable copies so load works regardless
            // of which domain the item was stored in.
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
            // Clear both local and synchronizable copies.
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

        return true
    }

    /// Re-saves every stored API key into the current (synchronizable) domain, unconditionally.
    /// Used by the one-time migration so keys saved by the old build's non-sync domain propagate.
    static func resaveAllSynchronizable() {
        for item in APIKeyItem.allCases {
            if let value = loadAPIKey(for: item) { saveAPIKey(value, for: item) }
        }
    }

}
