import Foundation
import Security

enum KeychainService: Sendable {

    // MARK: - Keys

    private static let authTokenKey = "authToken"
    private static let serverURLKey = "serverURL"
    private static let emailKey = "email"

    // MARK: - Core Operations

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first to avoid duplicates
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
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
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Convenience Methods

    static func saveCredentials(serverURL: String, email: String, token: String) {
        save(key: serverURLKey, value: serverURL)
        save(key: emailKey, value: email)
        save(key: authTokenKey, value: token)
    }

    static func loadServerURL() -> String? {
        load(key: serverURLKey)
    }

    static func loadEmail() -> String? {
        load(key: emailKey)
    }

    static func loadAuthToken() -> String? {
        load(key: authTokenKey)
    }

    static func clearAll() {
        delete(key: authTokenKey)
        delete(key: serverURLKey)
        delete(key: emailKey)
    }
}
