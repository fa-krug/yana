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
    private let log = Logger(subsystem: "de.fa-krug.Yana", category: "ArticleSync")

    init(container: CKContainer = CKContainer(identifier: "iCloud.de.fa-krug.Yana"),
         defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
        super.init()
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
        case .sentRecordZoneChanges, .sentDatabaseChanges, .fetchedDatabaseChanges,
             .willFetchChanges, .didFetchChanges, .willSendChanges, .didSendChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .accountChange:
            break
        @unknown default:
            break
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
            return Self.ckRecord(from: image, zoneID: zoneID)
        }
        return nil
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

    private static func ckRecord(from image: SyncedImageRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: imageRecordType, recordID: CKRecord.ID(recordName: image.hash, zoneID: zoneID))
        record["ext"] = image.ext as CKRecordValue
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(image.hash).\(image.ext)")
        try? image.data.write(to: tmp)
        record["blob"] = CKAsset(fileURL: tmp)
        return record
    }

    private static func imageRecord(from record: CKRecord) -> SyncedImageRecord? {
        guard let asset = record["blob"] as? CKAsset, let url = asset.fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return SyncedImageRecord(hash: record.recordID.recordName, ext: record["ext"] as? String ?? "img", data: data)
    }
}
