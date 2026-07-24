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
        defaults: UserDefaults = .standard
    ) {
        self.makeStore = store
        self.context = context
        self.settings = settings
        self.defaults = defaults
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
        try? context.save()
    }

    /// The canonical (first-writer) createdAt for a UID, if a pull has seen it.
    func canonicalCreatedAt(forUID uid: String) -> Date? { canonicalCreatedAtByUID[uid] }

    // MARK: Helpers

    /// Link orphan articles (feed == nil) to a now-present feed by their stored sync identity.
    private func relinkOrphans(feedsByKey: [String: Feed], starredTag: Tag?) {
        let orphans = (try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.feed == nil }))) ?? []
        for article in orphans where !article.syncFeedIdentifier.isEmpty {
            let key = ArticleRecordApply.feedKey(
                feedIdentifier: article.syncFeedIdentifier, aggregatorType: article.syncAggregatorType)
            guard let feed = feedsByKey[key] else { continue }
            article.feed = feed
            article.tags = feed.tags
            if let starredTag, article.isStarred, !article.tags.contains(where: { $0.id == starredTag.id }) {
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
