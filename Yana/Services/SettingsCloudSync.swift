import Foundation

/// Abstraction over the iCloud key-value store so tests inject an in-memory fake.
protocol KeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Data, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStore {
    func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }

    func set(_ value: Data, forKey key: String) {
        set(value as Any, forKey: key)
    }
}

extension KeyValueStore where Self == NSUbiquitousKeyValueStore {
    static var ubiquitous: NSUbiquitousKeyValueStore { .default }
}

/// Syncs the allow-listed non-secret settings across devices via `NSUbiquitousKeyValueStore`.
/// Feeds/tags/articles/images sync natively through SwiftData+CloudKit; this covers only the
/// UserDefaults-backed prefs SwiftData can't carry. Device-local prefs (updateInterval, voice,
/// onboarding, filter state, window layout) are excluded by virtue of not being in `SyncedSettings`.
@MainActor
enum SettingsCloudSync {
    static let key = "yana.syncedSettings"

    /// True when a UI-test/screenshot run must not touch the developer's real synced prefs.
    static var isSuppressed: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-UITEST_SCREENSHOTS")
            || args.contains("-UITEST_RESET_LIBRARY")
            || args.contains("-UITEST_SKIP_ONBOARDING")
    }

    static func push(_ settings: AppSettings, store: KeyValueStore = NSUbiquitousKeyValueStore.default) {
        guard !isSuppressed else { return }
        store.set(settings.exportSyncedSettings(), forKey: key)
        store.synchronize()
    }

    static func pull(into settings: AppSettings, store: KeyValueStore = NSUbiquitousKeyValueStore.default) {
        guard !isSuppressed, let data = store.data(forKey: key) else { return }
        settings.applySyncedSettings(data)
    }

    /// Pull once and observe external changes so remote edits apply live. Call at launch.
    static func start(_ settings: AppSettings) {
        guard !isSuppressed else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
        pull(into: settings)
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { pull(into: settings) }
        }
    }
}
