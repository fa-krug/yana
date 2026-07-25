import Foundation
import SwiftData
import CloudKit
import os

/// The single payload synced across a user's devices. Carries the feed/tag configuration
/// (as OPML) and the allow-listed non-secret settings — but never article bodies. Starred marks
/// ride along on synced article records instead of this document. Both fields serialize to
/// CloudKit as simple values.
struct ConfigDocument: Sendable, Equatable {
    var opml: String
    var settingsData: Data
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

    /// Field keys of the `ConfigDocument` record type. Named so `CloudKitSchemaBootstrap` pushes the
    /// exact same field set this store writes, instead of a hand-copied duplicate that can drift.
    static let opmlKey = "opml"
    static let settingsDataKey = "settingsData"

    func save(_ document: ConfigDocument) async throws {
        let record = cachedRecord ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        record[Self.opmlKey] = document.opml as CKRecordValue
        record[Self.settingsDataKey] = document.settingsData as CKRecordValue
        do {
            let saved = try await database.save(record)
            cachedRecord = saved
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw ConfigStoreError.conflict
        }
    }

    private static func document(from record: CKRecord) -> ConfigDocument {
        let opml = record[opmlKey] as? String ?? ""
        let settingsData = record[settingsDataKey] as? Data ?? Data()
        return ConfigDocument(opml: opml, settingsData: settingsData)
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
        defaults: UserDefaults = .standard
    ) {
        self.makeStore = store
        self.context = context
        self.settings = settings
        self.defaults = defaults
    }

    // MARK: Document construction

    /// Build the payload from current local state.
    func buildDocument() -> ConfigDocument {
        ConfigDocument(
            opml: FeedPortability.exportOPML(context: context),
            settingsData: settings.exportSyncedSettings()
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

        // 5. Persist + record the new snapshot.
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
        // CKSyncEngine collapses the real server rejection into a generic wrapper ("Failed to send
        // changes") and buries the cause as a partial/underlying error, so walk the whole chain
        // rather than inspecting only the top-level error.
        let ckErrors = Self.ckErrors(in: error)

        // Known account/network/quota conditions get a friendly, actionable message.
        for ck in ckErrors {
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
                continue
            }
        }

        // Otherwise surface the most specific server reason so a schema/validation rejection (e.g. a
        // field or record type not yet deployed to the Production CloudKit schema) is diagnosable
        // from the UI instead of the opaque "Failed to send changes" wrapper.
        if let specific = ckErrors.first(where: { $0.code != .partialFailure }) {
            let codeName = Self.codeName(for: specific.code)
            if let serverReason = specific.errorUserInfo["ServerErrorDescription"] as? String,
               !serverReason.isEmpty {
                return "\(serverReason) (\(codeName))"
            }
            return "\(specific.localizedDescription) (\(codeName))"
        }
        return error.localizedDescription
    }

    /// A readable name for a `CKError.Code`. `String(describing:)` yields an opaque
    /// `CKErrorCode(rawValue: 15)`, so map the codes worth diagnosing (schema/validation rejections
    /// especially) to their symbolic names, falling back to the raw value for the rest.
    private static func codeName(for code: CKError.Code) -> String {
        switch code {
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .invalidArguments: return "invalidArguments"
        case .constraintViolation: return "constraintViolation"
        case .serverRecordChanged: return "serverRecordChanged"
        case .unknownItem: return "unknownItem"
        case .zoneNotFound: return "zoneNotFound"
        case .userDeletedZone: return "userDeletedZone"
        case .badContainer: return "badContainer"
        case .badDatabase: return "badDatabase"
        case .internalError: return "internalError"
        case .limitExceeded: return "limitExceeded"
        case .quotaExceeded: return "quotaExceeded"
        case .partialFailure: return "partialFailure"
        case .serverResponseLost: return "serverResponseLost"
        case .incompatibleVersion: return "incompatibleVersion"
        case .requestRateLimited: return "requestRateLimited"
        case .serviceUnavailable: return "serviceUnavailable"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .managedAccountRestricted: return "managedAccountRestricted"
        default: return "code \(code.rawValue)"
        }
    }

    /// Flatten a CloudKit error chain — partial failures and underlying errors — into the `CKError`s
    /// it contains, outermost first. `CKSyncEngine` wraps the real server rejection this way, so the
    /// actionable cause is often several links down. Depth-bounded to guard against cyclic chains.
    private static func ckErrors(in error: Error) -> [CKError] {
        var found: [CKError] = []
        func walk(_ error: Error, depth: Int) {
            guard depth < 6 else { return }
            let ns = error as NSError
            if let ck = error as? CKError {
                found.append(ck)
                if let partials = ck.partialErrorsByItemID {
                    for sub in partials.values { walk(sub, depth: depth + 1) }
                }
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
                walk(underlying, depth: depth + 1)
            }
            if let multiple = ns.userInfo["NSMultipleUnderlyingErrorsKey"] as? [Error] {
                for sub in multiple { walk(sub, depth: depth + 1) }
            }
        }
        walk(error, depth: 0)
        return found
    }
}
