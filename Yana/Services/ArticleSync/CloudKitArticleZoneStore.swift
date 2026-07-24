import Foundation
import CloudKit
import os

/// Production `ArticleZoneStore` backed by `CKSyncEngine` over a dedicated `Articles` record zone in
/// the app's private database. `CKSyncEngine` owns change-token/state persistence and retry; this
/// adapter translates between our `Sendable` record structs and `CKRecord`s and buffers incoming
/// remote changes for `fetchChanges()` to drain.
@MainActor
final class CloudKitArticleZoneStore: NSObject, ArticleZoneStore, CKSyncEngineDelegate {
    static let articleRecordType = "SyncedArticle"
    static let imageRecordType = "SyncedImage"
    static let zoneName = "Articles"

    private let container: CKContainer
    private lazy var database = container.privateCloudDatabase
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitArticleZoneStore.zoneName)
    private let defaults: UserDefaults
    private let stateKey = "articleSync.engineState"

    private var _engine: CKSyncEngine?
    private var incoming = ArticleZoneChanges.empty
    private var pendingImageUploads: [String: SyncedImageRecord] = [:]   // hash -> record awaiting send
    // Cache of records to serialize when the engine asks for a batch (recordName -> struct).
    private var articleRecordCache: [String: SyncedArticleRecord] = [:]
    // Image-hash -> temp file backing a `CKAsset`, deleted once the record is confirmed saved or dropped.
    private var imageTempFiles: [String: URL] = [:]
    // Dedicated subdirectory for image `CKAsset` temp files so we can wipe leftovers on launch.
    private let assetTempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("YanaArticleSyncAssets", isDirectory: true)
    private let log = Logger(subsystem: "de.fa-krug.Yana", category: "ArticleSync")

    init(container: CKContainer = CKContainer(identifier: "iCloud.de.fa-krug.Yana"),
         defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
        super.init()
        prepareAssetTempDir()
    }

    /// Wipe any temp assets left over from a prior process so they don't accumulate across launches,
    /// then re-create the empty subdirectory.
    private func prepareAssetTempDir() {
        let fm = FileManager.default
        try? fm.removeItem(at: assetTempDir)
        try? fm.createDirectory(at: assetTempDir, withIntermediateDirectories: true)
    }

    private func engine() -> CKSyncEngine {
        if let _engine { return _engine }
        var config = CKSyncEngine.Configuration(
            database: database, stateSerialization: savedState(), delegate: self)
        config.automaticallySync = true
        let engine = CKSyncEngine(config)
        _engine = engine
        return engine
    }

    // MARK: ArticleZoneStore

    func fetchChanges() async throws -> ArticleZoneChanges {
        try await engine().fetchChanges()
        let drained = incoming
        incoming = .empty
        return drained
    }

    func upsert(articles: [SyncedArticleRecord], images: [SyncedImageRecord]) async throws {
        // Ensure the custom zone exists before the first save.
        engine().state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        for image in images { pendingImageUploads[image.hash] = image }
        for article in articles { articleRecordCache[article.uid] = article }
        let ids = articles.map { CKRecord.ID(recordName: $0.uid, zoneID: zoneID) }
            + images.map { CKRecord.ID(recordName: $0.hash, zoneID: zoneID) }
        engine().state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
        try await engine().sendChanges()
    }

    func delete(articleUIDs: [String]) async throws {
        let ids = articleUIDs.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        engine().state.add(pendingRecordZoneChanges: ids.map { .deleteRecord($0) })
        try await engine().sendChanges()
    }

    func fetchImage(hash: String) async throws -> SyncedImageRecord? {
        let id = CKRecord.ID(recordName: hash, zoneID: zoneID)
        do {
            let record = try await database.record(for: id)
            return Self.imageRecord(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            defaults.set(try? JSONEncoder().encode(update.stateSerialization), forKey: stateKey)
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                let record = modification.record
                if record.recordType == Self.articleRecordType,
                   let article = Self.articleRecord(from: record) {
                    incoming.articles.append(article)
                }
            }
            for deletion in changes.deletions where deletion.recordType == Self.articleRecordType {
                incoming.deletedUIDs.append(deletion.recordID.recordName)
            }
        case .sentRecordZoneChanges(let changes):
            handleSentRecordZoneChanges(changes, syncEngine: syncEngine)
        case .sentDatabaseChanges(let changes):
            handleSentDatabaseChanges(changes, syncEngine: syncEngine)
        case .fetchedDatabaseChanges,
             .willFetchChanges, .didFetchChanges, .willSendChanges, .didSendChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .accountChange:
            break
        @unknown default:
            break
        }
    }

    /// CKSyncEngine reports per-record push results here (and does NOT auto-retry non-transient
    /// errors, nor throw them from `sendChanges()`), so success pruning and error recovery both
    /// happen in this callback. Runs on the main actor with the rest of the adapter's state.
    private func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges,
                                             syncEngine: CKSyncEngine) {
        // Bound the caches: a record that's been saved no longer needs to be re-serialized, and its
        // asset temp file can go.
        for saved in event.savedRecords {
            forget(recordName: saved.recordID.recordName)
        }

        var recordChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        var databaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
        for failure in event.failedRecordSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // Server copy diverged. Bodies are last-writer-wins, so re-queue the save to let our
                // copy win on the next batch.
                recordChanges.append(.saveRecord(recordID))
            case .zoneNotFound, .userDeletedZone:
                // The custom zone is gone. Recreate it and re-queue the failed save.
                databaseChanges.append(.saveZone(CKRecordZone(zoneID: zoneID)))
                recordChanges.append(.saveRecord(recordID))
            case .unknownItem:
                // Stale reference; drop it from the caches (and its temp file) without re-queuing.
                forget(recordName: recordID.recordName)
            default:
                // Transient/other: leave it for CKSyncEngine's own auto-retry.
                log.debug("Leaving record save error to auto-retry: \(failure.error, privacy: .public)")
            }
        }
        if !databaseChanges.isEmpty { syncEngine.state.add(pendingDatabaseChanges: databaseChanges) }
        if !recordChanges.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: recordChanges) }
    }

    /// Zone save failures surface here. Re-queue a failed zone creation (idempotent; CKSyncEngine
    /// dedupes pending changes) unless the error is transient, in which case the engine retries it.
    private func handleSentDatabaseChanges(_ event: CKSyncEngine.Event.SentDatabaseChanges,
                                           syncEngine: CKSyncEngine) {
        var databaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
        for failure in event.failedZoneSaves {
            switch failure.error.code {
            case .networkFailure, .networkUnavailable, .serviceUnavailable, .zoneBusy,
                 .requestRateLimited, .notAuthenticated, .operationCancelled:
                log.debug("Leaving zone save error to auto-retry: \(failure.error, privacy: .public)")
            default:
                databaseChanges.append(.saveZone(CKRecordZone(zoneID: failure.zone.zoneID)))
            }
        }
        if !databaseChanges.isEmpty { syncEngine.state.add(pendingDatabaseChanges: databaseChanges) }
    }

    /// Drop a record from the send caches and delete its backing asset temp file, if any. Used both
    /// when a record is confirmed saved and when it's found to be a stale (`.unknownItem`) reference.
    private func forget(recordName: String) {
        articleRecordCache[recordName] = nil
        pendingImageUploads[recordName] = nil
        if let url = imageTempFiles.removeValue(forKey: recordName) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            await self?.batchRecord(for: recordID)
        }
    }

    /// Build the `CKRecord` for a pending change from the in-memory caches (main-actor state). Called
    /// from the engine's `@Sendable` record provider, which hops here via `await`.
    private func batchRecord(for recordID: CKRecord.ID) -> CKRecord? {
        let name = recordID.recordName
        if let article = articleRecordCache[name] {
            return Self.ckRecord(from: article, zoneID: zoneID)
        }
        if let image = pendingImageUploads[name] {
            return ckRecord(from: image)
        }
        return nil
    }

    /// Serialize an image into a `CKRecord`, writing its `CKAsset` blob to a tracked temp file in the
    /// dedicated asset subdirectory. The temp file is deleted once the record is confirmed saved (or
    /// dropped as stale) — see `forget(recordName:)`.
    private func ckRecord(from image: SyncedImageRecord) -> CKRecord {
        let record = CKRecord(recordType: Self.imageRecordType,
                              recordID: CKRecord.ID(recordName: image.hash, zoneID: zoneID))
        record["ext"] = image.ext as CKRecordValue
        let tmp = assetTempDir.appendingPathComponent("\(image.hash).\(image.ext)")
        try? image.data.write(to: tmp)
        imageTempFiles[image.hash] = tmp
        record["blob"] = CKAsset(fileURL: tmp)
        return record
    }

    // MARK: Serialization

    private func savedState() -> CKSyncEngine.State.Serialization? {
        guard let data = defaults.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func ckRecord(from a: SyncedArticleRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: articleRecordType, recordID: CKRecord.ID(recordName: a.uid, zoneID: zoneID))
        record["feedIdentifier"] = a.feedIdentifier as CKRecordValue
        record["aggregatorType"] = a.aggregatorType as CKRecordValue
        record["articleIdentifier"] = a.articleIdentifier as CKRecordValue
        record["title"] = a.title as CKRecordValue
        record["url"] = a.url as CKRecordValue
        record["author"] = a.author as CKRecordValue
        record["summary"] = a.summary as CKRecordValue
        record["plainText"] = a.plainText as CKRecordValue
        record["leadImageRef"] = a.leadImageRef as CKRecordValue
        record["iconURL"] = a.iconURL as CKRecordValue?
        record["date"] = a.date as CKRecordValue
        record["createdAt"] = a.createdAt as CKRecordValue
        record["blockData"] = a.blockData as CKRecordValue
        record["isStarred"] = (a.isStarred ? 1 : 0) as CKRecordValue
        record["tagNames"] = a.tagNames as CKRecordValue
        record["imageHashes"] = a.imageHashes as CKRecordValue
        return record
    }

    private static func articleRecord(from record: CKRecord) -> SyncedArticleRecord? {
        guard let feedIdentifier = record["feedIdentifier"] as? String,
              let aggregatorType = record["aggregatorType"] as? String,
              let articleIdentifier = record["articleIdentifier"] as? String,
              let date = record["date"] as? Date,
              let createdAt = record["createdAt"] as? Date else { return nil }
        return SyncedArticleRecord(
            uid: record.recordID.recordName,
            feedIdentifier: feedIdentifier, aggregatorType: aggregatorType, articleIdentifier: articleIdentifier,
            title: record["title"] as? String ?? "", url: record["url"] as? String ?? "",
            author: record["author"] as? String ?? "", summary: record["summary"] as? String ?? "",
            plainText: record["plainText"] as? String ?? "", leadImageRef: record["leadImageRef"] as? String ?? "",
            iconURL: record["iconURL"] as? String, date: date, createdAt: createdAt,
            blockData: record["blockData"] as? Data ?? Data(),
            isStarred: (record["isStarred"] as? Int ?? 0) == 1,
            tagNames: record["tagNames"] as? [String] ?? [],
            imageHashes: record["imageHashes"] as? [String] ?? [])
    }

    private static func imageRecord(from record: CKRecord) -> SyncedImageRecord? {
        guard let asset = record["blob"] as? CKAsset, let url = asset.fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return SyncedImageRecord(hash: record.recordID.recordName, ext: record["ext"] as? String ?? "img", data: data)
    }
}
