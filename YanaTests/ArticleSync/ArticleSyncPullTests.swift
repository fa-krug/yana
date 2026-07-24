import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSync pull")
struct ArticleSyncPullTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "ArticleSyncPull.\(UUID().uuidString)")! }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func makeService(_ store: FakeArticleZoneStore, _ context: ModelContext, enabled: Bool = true)
        -> (ArticleSyncService, AppSettings) {
        let settings = AppSettings(defaults: suite())
        settings.iCloudSyncEnabled = enabled
        let service = ArticleSyncService(store: store, context: context, settings: settings, defaults: suite())
        return (service, settings)
    }

    private func record(uid: String, feed: String, identifier: String, title: String,
                        createdAt: Date = .now) -> SyncedArticleRecord {
        SyncedArticleRecord(
            uid: uid, feedIdentifier: feed, aggregatorType: "feed_content", articleIdentifier: identifier,
            title: title, url: "https://x/\(identifier)", author: "", summary: "", plainText: title,
            leadImageRef: "", iconURL: nil, date: .now, createdAt: createdAt, blockData: Data(),
            isStarred: false, tagNames: [], imageHashes: [])
    }

    @Test("Pull materializes a remote article linked to its local feed")
    func pullCreatesLinked() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        try context.save()

        let store = FakeArticleZoneStore()
        store.seedRemote(record(uid: "f1|feed_content|a1", feed: "f1", identifier: "a1", title: "Hi"))
        let (service, _) = makeService(store, context)

        await service.pull()

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)
        #expect(articles.first?.feed === feed)
    }

    @Test("Pull skips a UID already present locally (dedup)")
    func pullDedupes() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let existing = Article(title: "Old", identifier: "a1", url: "https://x/a1")
        existing.feed = feed
        context.insert(existing)
        try context.save()

        let store = FakeArticleZoneStore()
        store.seedRemote(record(uid: "f1|feed_content|a1", feed: "f1", identifier: "a1", title: "New"))
        let (service, _) = makeService(store, context)

        await service.pull()

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)                       // updated, not duplicated
        #expect(articles.first?.title == "New")
    }

    @Test("A tombstone removes the local article")
    func pullTombstone() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let existing = Article(title: "Doomed", identifier: "a1", url: "https://x/a1")
        existing.feed = feed
        context.insert(existing)
        try context.save()

        let store = FakeArticleZoneStore()
        store.pendingChanges = ArticleZoneChanges(articles: [], deletedUIDs: ["f1|feed_content|a1"])
        let (service, _) = makeService(store, context)

        await service.pull()
        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.isEmpty)
    }

    @Test("canonicalCreatedAt reports the createdAt of a pulled record")
    func canonicalCreatedAt() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        try context.save()
        let store = FakeArticleZoneStore()
        let t = Date(timeIntervalSince1970: 777)
        store.seedRemote(record(uid: "f1|feed_content|a1", feed: "f1", identifier: "a1", title: "Hi", createdAt: t))
        let (service, _) = makeService(store, context)
        await service.pull()
        #expect(service.canonicalCreatedAt(forUID: "f1|feed_content|a1") == t)
    }

    @Test("Pull is a no-op when sync is disabled")
    func disabledNoOp() async throws {
        let context = try makeContext()
        let store = FakeArticleZoneStore()
        store.seedRemote(record(uid: "f1|feed_content|a1", feed: "f1", identifier: "a1", title: "Hi"))
        let (service, _) = makeService(store, context, enabled: false)
        await service.pull()
        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.isEmpty)
    }

    @Test("Reconcile re-links a pre-existing orphan when its feed is present")
    func relinkOrphan() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let orphan = Article(title: "Orphan", identifier: "a1", url: "https://x/a1")
        orphan.syncFeedIdentifier = "f1"; orphan.syncAggregatorType = "feed_content"
        context.insert(orphan)              // feed left nil
        try context.save()
        let store = FakeArticleZoneStore()
        let (service, _) = makeService(store, context)
        await service.pull()               // no incoming records; relink pass should still run
        #expect(orphan.feed === feed)
    }
}
