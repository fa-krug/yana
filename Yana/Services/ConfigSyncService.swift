import Foundation
import SwiftData
import CloudKit
import os

/// The single payload synced across a user's devices. Carries the feed/tag configuration
/// (as OPML), the allow-listed non-secret settings, and the starred-article set — but never
/// article bodies. All three fields serialize to CloudKit as simple values.
struct ConfigDocument: Sendable, Equatable {
    var opml: String
    var settingsData: Data
    var starredData: Data

    /// Encode a starred set as JSON `Data`.
    static func encodeStarred(_ marks: Set<StarredMark>) -> Data {
        (try? JSONEncoder().encode(marks)) ?? Data()
    }

    /// Decode JSON `Data` back into a starred set (empty on failure).
    static func decodeStarred(_ data: Data) -> Set<StarredMark> {
        (try? JSONDecoder().decode(Set<StarredMark>.self, from: data)) ?? []
    }
}

/// Abstraction over the remote store so the service is unit-testable without CloudKit.
protocol ConfigStore: Sendable {
    /// Fetch the single config record. `nil` when no record exists yet.
    func fetch() async throws -> ConfigDocument?
    /// Persist the single config record.
    func save(_ document: ConfigDocument) async throws
}

enum ConfigStoreError: Error {
    /// The server copy changed since we last fetched (CloudKit `serverRecordChanged`).
    /// The service reacts by pulling, rebuilding, and retrying the save once.
    case conflict
}

// MARK: - CloudKit store

/// Production `ConfigStore` backed by the app's private CloudKit database. Holds one record
/// (`ConfigDocument`/`config`) and caches the last-fetched `CKRecord` so a subsequent save
/// reuses its change tag. `@MainActor` for Sendable-clean mutable state; CloudKit's async APIs
/// are fine to await from the main actor.
@MainActor
final class CloudKitConfigStore: ConfigStore {
    static let recordType = "ConfigDocument"
    static let recordName = "config"
    private static let subscriptionID = "config-changes"
    private static let subscriptionDefaultsKey = "sync.subscriptionRegistered"

    private let database: CKDatabase
    private let defaults: UserDefaults
    private var cachedRecord: CKRecord?

    private let log = Logger(subsystem: "de.fa-krug.Yana", category: "ConfigSync")

    init(
        container: CKContainer = CKContainer(identifier: "iCloud.de.fa-krug.Yana"),
        defaults: UserDefaults = .standard
    ) {
        self.database = container.privateCloudDatabase
        self.defaults = defaults
    }

    private var recordID: CKRecord.ID { CKRecord.ID(recordName: Self.recordName) }

    func fetch() async throws -> ConfigDocument? {
        do {
            let record = try await database.record(for: recordID)
            cachedRecord = record
            return Self.document(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func save(_ document: ConfigDocument) async throws {
        let record = cachedRecord ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        record["opml"] = document.opml as CKRecordValue
        record["settingsData"] = document.settingsData as CKRecordValue
        record["starredData"] = document.starredData as CKRecordValue
        do {
            let saved = try await database.save(record)
            cachedRecord = saved
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw ConfigStoreError.conflict
        }
    }

    private static func document(from record: CKRecord) -> ConfigDocument {
        let opml = record["opml"] as? String ?? ""
        let settingsData = record["settingsData"] as? Data ?? Data()
        let starredData = record["starredData"] as? Data ?? Data()
        return ConfigDocument(opml: opml, settingsData: settingsData, starredData: starredData)
    }

    /// Create a silent database subscription once (guarded by a device-local flag), so remote
    /// changes wake the app to pull. No-op after the first successful registration.
    func registerSubscriptionIfNeeded() async throws {
        guard !defaults.bool(forKey: Self.subscriptionDefaultsKey) else { return }
        let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
        defaults.set(true, forKey: Self.subscriptionDefaultsKey)
    }
}

// MARK: - Service

/// Orchestrates optional iCloud sync of the app's configuration. Everything is gated on
/// `AppSettings.iCloudSyncEnabled`; when off, all entry points return immediately.
///
/// The merge model (`reconcile`) is additive for feeds/tags (via `FeedPortability.importOPML`)
/// with an explicit deletion reconcile keyed off a device-local "last synced feed keys" snapshot:
/// a feed present in that snapshot but absent from the incoming document was deleted elsewhere and
/// is removed locally; a local feed absent from the snapshot is a not-yet-pushed local addition and
/// is preserved.
@MainActor
@Observable
final class ConfigSyncService {
    /// Factory for the remote store, invoked lazily on first use. Deferring construction keeps the
    /// production `CloudKitConfigStore` (and its `CKContainer`) off the launch path entirely when
    /// iCloud sync is disabled — the default — since every entry point that touches `store` is gated
    /// on `iCloudSyncEnabled` and returns before reaching it.
    @ObservationIgnored private let makeStore: () -> ConfigStore
    @ObservationIgnored private lazy var store: ConfigStore = makeStore()
    private let context: ModelContext
    private let settings: AppSettings
    private let starred: StarredRegistry
    @ObservationIgnored private let defaults: UserDefaults

    /// Human-readable description of the most recent push/pull failure, or `nil` after a success.
    /// Surfaced in the iCloud Sync settings section so failures aren't silently swallowed —
    /// without this, a failing CloudKit write (no iCloud account, unprovisioned container, etc.)
    /// looks identical to "nothing to sync".
    private(set) var lastSyncError: String?

    private static let lastFeedKeysDefaultsKey = "sync.lastFeedKeys"
    private static let debounceInterval: Duration = .seconds(2)

    @ObservationIgnored private var pendingPush: Task<Void, Never>?

    private let log = Logger(subsystem: "de.fa-krug.Yana", category: "ConfigSync")

    /// Shared instance wired to the production CloudKit store and the app's main context. The
    /// `CloudKitConfigStore()` argument is an `@autoclosure`, so it is NOT evaluated here — the
    /// `CKContainer` is built only on first store access, which never happens while sync is off.
    static let shared = ConfigSyncService(
        store: CloudKitConfigStore(),
        context: AppContainer.shared.mainContext,
        settings: AppSettings()
    )

    init(
        store: @autoclosure @escaping () -> ConfigStore,
        context: ModelContext,
        settings: AppSettings,
        starred: StarredRegistry = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.makeStore = store
        self.context = context
        self.settings = settings
        self.starred = starred
        self.defaults = defaults
    }

    // MARK: Document construction

    /// Build the payload from current local state.
    func buildDocument() -> ConfigDocument {
        ConfigDocument(
            opml: FeedPortability.exportOPML(context: context),
            settingsData: settings.exportSyncedSettings(),
            starredData: ConfigDocument.encodeStarred(StarredRegistry.collect(from: context))
        )
    }

    // MARK: Push

    /// Debounced push entry point for mutation sites. Coalesces rapid calls into a single push.
    func requestPush() {
        guard settings.iCloudSyncEnabled else { return }
        pendingPush?.cancel()
        pendingPush = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    /// Save the current local state to the store. On a conflict, pull the server state in, rebuild,
    /// and retry the save once. Non-conflict errors (e.g. no iCloud account) are swallowed/logged.
    func push() async {
        guard settings.iCloudSyncEnabled else { return }
        let document = buildDocument()
        do {
            try await store.save(document)
            setLastFeedKeys(currentLocalFeedKeys())
            lastSyncError = nil
        } catch ConfigStoreError.conflict {
            await pull()
            let rebuilt = buildDocument()
            do {
                try await store.save(rebuilt)
                setLastFeedKeys(currentLocalFeedKeys())
                lastSyncError = nil
            } catch {
                log.error("Push retry after conflict failed: \(String(describing: error))")
                lastSyncError = Self.describe(error)
            }
        } catch {
            log.error("Push failed: \(String(describing: error))")
            lastSyncError = Self.describe(error)
        }
    }

    // MARK: Pull

    /// Fetch the remote document and reconcile it into local state. No-op when nothing is remote yet.
    func pull() async {
        guard settings.iCloudSyncEnabled else { return }
        do {
            guard let document = try await store.fetch() else { return }
            reconcile(document)
            lastSyncError = nil
        } catch {
            log.error("Pull failed: \(String(describing: error))")
            lastSyncError = Self.describe(error)
        }
    }

    /// Merge a document into local state. Kept public so tests can drive it directly.
    func reconcile(_ document: ConfigDocument) {
        // 1. Incoming feed keys (mirror FeedPortability's key format exactly).
        let incomingKeys = Set(OPMLCodec.decode(document.opml).map { dto -> String in
            let type = AggregatorType(rawValue: dto.aggregatorType ?? "") ?? .feedContent
            return "\(dto.identifier)|\(type.rawValue)"
        })

        // 2. Additive import (adds new feeds/tags, dedupes existing).
        FeedPortability.importOPML(document.opml, context: context)

        // 3. Deletion reconcile: remove feeds that were in the last synced snapshot but are gone now.
        let toDelete = lastFeedKeys().subtracting(incomingKeys)
        if !toDelete.isEmpty {
            let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
            for feed in feeds where toDelete.contains("\(feed.identifier)|\(feed.aggregatorType)") {
                context.delete(feed) // cascade removes its articles
            }
        }

        // 4. Settings.
        settings.applySyncedSettings(document.settingsData)

        // 5. Starred set. The remote set is authoritative (last-writer-wins): this replaces the
        // local starred state rather than unioning it. A star toggled locally within the debounce
        // window before an interleaving pull can therefore be dropped if the incoming document
        // predates it — an accepted limitation of the single-record model, not a bug. Stars
        // re-converge on the next push; if losing a local star ever proves annoying in practice,
        // switch this to a union-on-pull.
        starred.update(to: ConfigDocument.decodeStarred(document.starredData))
        starred.applyToLocalArticles(in: context)

        // 6. Persist + record the new snapshot.
        try? context.save()
        setLastFeedKeys(incomingKeys)
    }

    // MARK: Lifecycle

    /// On enable/launch: register the CloudKit subscription (best-effort) and pull once.
    func start() async {
        guard settings.iCloudSyncEnabled else { return }
        if let ckStore = store as? CloudKitConfigStore {
            try? await ckStore.registerSubscriptionIfNeeded()
        }
        await pull()
    }

    // MARK: Stop

    /// Cancel any pending debounced push and clear the device-local last-synced feed-keys snapshot
    /// so that re-enabling sync later performs a fresh union merge rather than issuing spurious deletions.
    func stop() {
        pendingPush?.cancel()
        pendingPush = nil
        defaults.removeObject(forKey: Self.lastFeedKeysDefaultsKey)
    }

    // MARK: Last-synced snapshot

    private func currentLocalFeedKeys() -> Set<String> {
        let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
        return Set(feeds.map { "\($0.identifier)|\($0.aggregatorType)" })
    }

    private func lastFeedKeys() -> Set<String> {
        guard let raw = defaults.stringArray(forKey: Self.lastFeedKeysDefaultsKey) else { return [] }
        return Set(raw)
    }

    private func setLastFeedKeys(_ keys: Set<String>) {
        defaults.set(Array(keys), forKey: Self.lastFeedKeysDefaultsKey)
    }

    // MARK: Error description

    /// Map a sync failure to a short, user-readable message. CloudKit's most common actionable
    /// failures (no signed-in account, network) get a tailored line; everything else falls back
    /// to the localized error description.
    static func describe(_ error: Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated:
                return String(localized: "Sign in to iCloud in Settings to sync.")
            case .networkUnavailable, .networkFailure:
                return String(localized: "iCloud is unreachable. Check your connection.")
            case .quotaExceeded:
                return String(localized: "Your iCloud storage is full.")
            case .managedAccountRestricted, .permissionFailure:
                return String(localized: "iCloud access is restricted for this account.")
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
