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

/// Coalesces a burst of timeline-anchor writes (continuous reader swiping, sidebar selection, or
/// Next/Previous Article) into a single `SettingsCloudSync.push`. Without this, every article the
/// user pages past would be its own `NSUbiquitousKeyValueStore` write — that store is not built for
/// high-frequency writes, and it is shared with every other synced key besides.
///
/// Interval: 3 seconds of quiet. Long enough that swiping through a handful of articles in a row
/// collapses into one write; short enough that a second device opening mid-session still sees a
/// reasonably fresh position rather than one several scrolls stale. The scene `.background` push
/// (`YanaApp.swift`) remains the guaranteed flush for whatever hasn't yet coalesced when the app is
/// backgrounded.
///
/// Instantiable (mirrors `LibraryRevision`) rather than a bare static so tests can inject a short
/// interval and a private `KeyValueStore` fake without waiting on production timing or touching
/// shared state between tests. `SettingsCloudSync.pushSoon` uses `.shared` in production.
@MainActor
final class AnchorPushCoalescer {
    static let shared = AnchorPushCoalescer()

    private let interval: Duration
    private var coalescer: TrailingCoalescer?
    /// The most recent (settings, store) pair to push once the quiet period elapses. Updated on
    /// every call so the coalescer always flushes the latest position, not a stale intermediate one.
    private var pending: (() -> Void)?

    init(interval: Duration = .seconds(3)) {
        self.interval = interval
    }

    func pushSoon(_ settings: AppSettings, store: KeyValueStore) {
        pending = { SettingsCloudSync.push(settings, store: store, logLevel: .debug) }
        let coalescer = coalescer ?? TrailingCoalescer(interval: interval) { [weak self] in
            self?.pending?()
        }
        self.coalescer = coalescer
        coalescer.schedule()
    }
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

    /// - Parameter logLevel: the `SyncLog` severity for the "Pushed…" line. Defaults to `.info` for
    ///   the one-shot/flush call sites (scene `.background`, the one-time migration) where a push is
    ///   a rare, noteworthy event. `pushSoon` below passes `.debug` instead — see its doc comment.
    static func push(
        _ settings: AppSettings,
        store: KeyValueStore = NSUbiquitousKeyValueStore.default,
        logLevel: SyncLog.Level = .info
    ) {
        guard !isSuppressed else { return }
        store.set(settings.exportSyncedSettings(), forKey: key)
        store.synchronize()
        SyncLog.shared.log(logLevel, "Settings", "Pushed synced settings to iCloud key-value store")
    }

    /// Coalesced push for high-frequency write sites — the timeline anchor updates on every reader
    /// swipe, sidebar selection, and Next/Previous Article. Call `push` directly for one-shot /
    /// flush sites (scene `.background`, the one-time migration); this defers to
    /// `AnchorPushCoalescer` so a burst of anchor changes becomes one write. See
    /// `AnchorPushCoalescer` for the chosen interval and rationale.
    ///
    /// Logs at `.debug`, not `.info`: KVS used to be written at most twice per launch, so an `.info`
    /// line was a rare, meaningful event; now a burst fires on every reading session, and the
    /// 2000-entry `SyncLog` buffer's whole reason for existing is to stay readable through the
    /// exact kind of sync storm this would otherwise flood it with. The explicit `.background` /
    /// migration `push` calls above keep `.info` — they are still a handful of calls per launch.
    static func pushSoon(
        _ settings: AppSettings,
        store: KeyValueStore = NSUbiquitousKeyValueStore.default,
        coalescer: AnchorPushCoalescer = .shared
    ) {
        guard !isSuppressed else { return }
        coalescer.pushSoon(settings, store: store)
    }

    static func pull(into settings: AppSettings, store: KeyValueStore = NSUbiquitousKeyValueStore.default) {
        guard !isSuppressed, let data = store.data(forKey: key) else { return }
        settings.applySyncedSettings(data)
        SyncLog.shared.info("Applied \(data.count) bytes of synced settings from iCloud", category: "Settings")
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
            MainActor.assumeIsolated {
                SyncLog.shared.info("Synced settings changed on another device", category: "Settings")
                pull(into: settings)
            }
        }
    }
}
