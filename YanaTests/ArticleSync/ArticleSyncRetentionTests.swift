import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Retention deletion propagation")
struct ArticleSyncRetentionTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "ArticleSyncRetention.\(UUID().uuidString)")! }
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config))
    }
    private func makeService(_ store: FakeArticleZoneStore, _ context: ModelContext, enabled: Bool = true)
        -> ArticleSyncService {
        let settings = AppSettings(defaults: suite())
        settings.iCloudSyncEnabled = enabled
        return ArticleSyncService(store: store, context: context, settings: settings, defaults: suite())
    }

    @Test("RetentionCleanup returns the UIDs it deleted, skipping starred")
    func returnsDeletedUIDs() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        let starredTag = try #require((try context.fetch(FetchDescriptor<Yana.Tag>(predicate: #Predicate { $0.isBuiltIn }))).first)
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)

        let old = Article(title: "Old", identifier: "a1", url: "https://x/1")
        old.feed = feed; old.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(old)

        let oldStarred = Article(title: "Keep", identifier: "a2", url: "https://x/2")
        oldStarred.feed = feed; oldStarred.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(oldStarred)
        oldStarred.setStarred(true, using: starredTag)
        try context.save()

        let deleted = RetentionCleanup.run(context: context, retentionDays: 30, now: Date(timeIntervalSince1970: 60 * 86_400))
        #expect(deleted == ["f1|feed_content|a1"])
    }

    @Test("A starred aged-out article is neither deleted nor returned")
    func starredSurvivesAndIsExcluded() throws {
        let context = try makeContext()
        Tag.ensureBuiltIns(in: context)
        let starredTag = try #require((try context.fetch(FetchDescriptor<Yana.Tag>(predicate: #Predicate { $0.isBuiltIn }))).first)
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)

        let oldStarred = Article(title: "Keep", identifier: "a2", url: "https://x/2")
        oldStarred.feed = feed; oldStarred.createdAt = Date(timeIntervalSince1970: 0)
        context.insert(oldStarred)
        oldStarred.setStarred(true, using: starredTag)
        try context.save()

        let deleted = RetentionCleanup.run(context: context, retentionDays: 30, now: Date(timeIntervalSince1970: 60 * 86_400))
        #expect(deleted.isEmpty)

        let remaining = try context.fetch(FetchDescriptor<Article>()).map(\.identifier)
        #expect(remaining == ["a2"])
    }

    @Test("deleteRemote tombstones the given UIDs and forgets their canonical createdAt")
    func deleteRemoteTombstones() async throws {
        let context = try makeContext()
        let store = FakeArticleZoneStore()
        store.seedRemote(SyncedArticleRecord(
            uid: "f1|feed_content|a1", feedIdentifier: "f1", aggregatorType: "feed_content",
            articleIdentifier: "a1", title: "T", url: "https://x/1", author: "", summary: "",
            plainText: "", leadImageRef: "", iconURL: nil, date: .now, createdAt: .now,
            blockData: Data(), isStarred: false, tagNames: [], imageHashes: []))
        let service = makeService(store, context)
        await service.pull()
        #expect(service.canonicalCreatedAt(forUID: "f1|feed_content|a1") != nil)

        await service.deleteRemote(uids: ["f1|feed_content|a1"])
        #expect(store.deletedUIDs == ["f1|feed_content|a1"])
        #expect(service.canonicalCreatedAt(forUID: "f1|feed_content|a1") == nil)
    }

    @Test("deleteRemote is a no-op when sync is disabled or the UID list is empty")
    func deleteRemoteNoOp() async throws {
        let context = try makeContext()
        let store = FakeArticleZoneStore()
        let disabled = makeService(store, context, enabled: false)
        await disabled.deleteRemote(uids: ["f1|feed_content|a1"])
        #expect(store.deletedUIDs.isEmpty)

        let enabled = makeService(store, context)
        await enabled.deleteRemote(uids: [])
        #expect(store.deletedUIDs.isEmpty)
    }
}
