import Foundation
import os

enum KeychainService: Sendable {
    private static let deviceTokenKey = "device_session_token"

    /// One-slot cache for the device token. `.none` = not yet read from Keychain;
    /// `.some(nil)` = read and absent; `.some(.some(t))` = read and present.
    /// Lock-protected because `deleteDeviceToken` is called off-main from
    /// `SyncEngine.backfillMissingContent`'s bounded task group.
    private static let deviceTokenCache = OSAllocatedUnfairLock<String??>(initialState: nil)

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
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
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    static func saveDeviceToken(_ token: String) -> Bool {
        let ok = save(key: deviceTokenKey, value: token)
        if ok { deviceTokenCache.withLock { $0 = .some(token) } }
        return ok
    }

    static func loadDeviceToken() -> String? {
        if let cached = deviceTokenCache.withLock({ $0 }) { return cached }
        let loaded = load(key: deviceTokenKey)
        deviceTokenCache.withLock { $0 = .some(loaded) }
        return loaded
    }

    @discardableResult
    static func deleteDeviceToken() -> Bool {
        let ok = delete(key: deviceTokenKey)
        deviceTokenCache.withLock { $0 = .some(nil) }
        return ok
    }
}
