import Foundation
import SwiftData
import CloudKit
import os

/// Orchestrates optional iCloud sync of full article content across devices. Gated on
/// `AppSettings.iCloudSyncEnabled`; every entry point returns immediately when off. Mirrors the
/// shape of `ConfigSyncService` (lazy store, main-actor, `lastSyncError`) but manages many records
/// in a dedicated zone via an `ArticleZoneStore`.
@MainActor
@Observable
final class ArticleSyncService {
    @ObservationIgnored private let makeStore: () -> ArticleZoneStore
    @ObservationIgnored private lazy var store: ArticleZoneStore = makeStore()
    private let context: ModelContext
    private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let imageStore: ImageStore

    /// UID → canonical `createdAt` learned from pulled records, so a locally aggregated insert with
    /// the same UID adopts the first-writer time instead of back-dating a fresh one.
    @ObservationIgnored private var canonicalCreatedAtByUID: [String: Date] = [:]

    private(set) var lastSyncError: String?

    private let log = Logger(subsystem: "de.fa-krug.Yana", category: "ArticleSync")

    static let shared = ArticleSyncService(
        store: CloudKitArticleZoneStore(),
        context: AppContainer.shared.mainContext,
        settings: AppSettings()
    )

    init(
        store: @autoclosure @escaping () -> ArticleZoneStore,
        context: ModelContext,
        settings: AppSettings,
        defaults: UserDefaults = .standard,
        imageStore: ImageStore = .shared
    ) {
        self.makeStore = store
        self.context = context
        self.settings = settings
        self.defaults = defaults
        self.imageStore = imageStore
    }

    // MARK: Pull

    /// Fetch remote changes and reconcile them into local state. No-op when sync is off.
    func pull() async {
        guard settings.iCloudSyncEnabled else { return }
        do {
            let changes = try await store.fetchChanges()
            reconcile(changes)
            lastSyncError = nil
        } catch {
            log.error("Article pull failed: \(String(describing: error))")
            lastSyncError = ConfigSyncService.describe(error)
        }
    }

    /// Merge a change set into local SwiftData. Public so tests can drive it directly.
    func reconcile(_ changes: ArticleZoneChanges) {
        let starredTag = starredTag()
        let feedsByKey = feedsByKey()

        for record in changes.articles {
            canonicalCreatedAtByUID[record.uid] = record.createdAt
            ArticleRecordApply.apply(record, into: context, starredTag: starredTag, feedsByKey: feedsByKey)
        }

        // Re-link any orphan (feed == nil) articles whose stored identity now matches a present
        // feed — covers records that synced before their feed arrived via config sync.
        relinkOrphans(feedsByKey: feedsByKey, starredTag: starredTag)

        if !changes.deletedUIDs.isEmpty {
            let deleted = Set(changes.deletedUIDs)
            let all = (try? context.fetch(FetchDescriptor<Article>())) ?? []
            for article in all {
                guard let uid = ArticleUID.make(for: article), deleted.contains(uid) else { continue }
                canonicalCreatedAtByUID[uid] = nil
                context.delete(article)
            }
        }

        // Hydrate referenced images off the reconcile path (best-effort, non-blocking).
        let incoming = changes.articles
        if !incoming.isEmpty {
            Task { [weak self] in await self?.hydrateImages(for: incoming) }
        }

        try? context.save()
    }

    /// The canonical (first-writer) createdAt for a UID, if a pull has seen it.
    func canonicalCreatedAt(forUID uid: String) -> Date? { canonicalCreatedAtByUID[uid] }

    // MARK: Push

    /// Upload every local article (migration / enable path).
    func pushAll() async {
        guard settings.iCloudSyncEnabled else { return }
        let all = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        await pushArticles(all)
    }

    /// Upload the local articles with the given UIDs (post-aggregation path).
    func push(uids: [String]) async {
        guard settings.iCloudSyncEnabled, !uids.isEmpty else { return }
        let wanted = Set(uids)
        let all = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        let matching = all.filter { ArticleUID.make(for: $0).map(wanted.contains) ?? false }
        await pushArticles(matching)
    }

    private func pushArticles(_ articles: [Article]) async {
        var records: [SyncedArticleRecord] = []
        var imageHashes = Set<String>()
        for article in articles {
            guard let record = SyncedArticleRecord(article: article) else { continue }
            records.append(record)
            imageHashes.formUnion(record.imageHashes)
        }
        guard !records.isEmpty else { return }

        // Gather the referenced image blobs from the local store (write-once dedup by hash).
        var images: [SyncedImageRecord] = []
        for hash in imageHashes {
            if let data = await imageStore.rawData(forHash: hash) {
                let ext = await imageStore.recordedExt(forHash: hash)
                images.append(SyncedImageRecord(hash: hash, ext: ext, data: data))
            }
        }

        do {
            try await store.upsert(articles: records, images: images)
            for record in records { canonicalCreatedAtByUID[record.uid] = record.createdAt }
            lastSyncError = nil
        } catch {
            log.error("Article push failed: \(String(describing: error))")
            lastSyncError = ConfigSyncService.describe(error)
        }
    }

    /// Tombstone the given UIDs in the zone. Gated; no-op when off or empty.
    func deleteRemote(uids: [String]) async {
        guard settings.iCloudSyncEnabled, !uids.isEmpty else { return }
        do {
            try await store.delete(articleUIDs: uids)
            for uid in uids { canonicalCreatedAtByUID[uid] = nil }
            lastSyncError = nil
        } catch {
            log.error("Article delete failed: \(String(describing: error))")
            lastSyncError = ConfigSyncService.describe(error)
        }
    }

    // MARK: Image hydration

    /// Download any image blobs referenced by the given records that are missing locally, writing
    /// them into the local `ImageStore` so `yana-img://` refs resolve. Failures are non-fatal — a
    /// body still renders, just without that image until a later pull.
    func hydrateImages(for records: [SyncedArticleRecord]) async {
        var needed = Set<String>()
        for record in records { needed.formUnion(record.imageHashes) }
        for hash in needed where !(await imageStore.fileExists(forHash: hash)) {
            if let image = try? await store.fetchImage(hash: hash) {
                _ = await imageStore.storeData(image.data, ext: image.ext)
            }
        }
    }

    // MARK: Helpers

    /// Link orphan articles (feed == nil) to a now-present feed by their stored sync identity.
    private func relinkOrphans(feedsByKey: [String: Feed], starredTag: Tag?) {
        let orphans = (try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.feed == nil }))) ?? []
        for article in orphans where !article.syncFeedIdentifier.isEmpty {
            let key = ArticleRecordApply.feedKey(
                feedIdentifier: article.syncFeedIdentifier, aggregatorType: article.syncAggregatorType)
            guard let feed = feedsByKey[key] else { continue }
            let wasStarred = article.isStarred      // read BEFORE tags are overwritten (isStarred is computed from tags)
            article.feed = feed
            article.tags = feed.tags
            if wasStarred, let starredTag, !article.tags.contains(where: { $0.id == starredTag.id }) {
                article.tags.append(starredTag)
            }
        }
    }

    private func feedsByKey() -> [String: Feed] {
        let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
        var map: [String: Feed] = [:]
        for feed in feeds {
            map[ArticleRecordApply.feedKey(feedIdentifier: feed.identifier, aggregatorType: feed.aggregatorType)] = feed
        }
        return map
    }

    private func starredTag() -> Tag? {
        Tag.ensureBuiltIns(in: context)
        return (try? context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })))?.first
    }
}
