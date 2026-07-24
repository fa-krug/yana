import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSync push")
struct ArticleSyncPushTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "ArticleSyncPush.\(UUID().uuidString)")! }
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

    @Test("pushAll uploads every local article by UID")
    func pushAllUploads() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        for i in 1...3 {
            let a = Article(title: "T\(i)", identifier: "a\(i)", url: "https://x/\(i)")
            a.feed = feed
            context.insert(a)
        }
        try context.save()
        let store = FakeArticleZoneStore()
        let service = makeService(store, context)

        await service.pushAll()
        #expect(Set(store.articlesUIDsForTest) == ["f1|feed_content|a1", "f1|feed_content|a2", "f1|feed_content|a3"])
    }

    @Test("push is a no-op when sync is disabled")
    func disabledNoOp() async throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let a = Article(title: "T", identifier: "a1", url: "https://x/1"); a.feed = feed; context.insert(a)
        try context.save()
        let store = FakeArticleZoneStore()
        let service = makeService(store, context, enabled: false)
        await service.pushAll()
        #expect(store.articlesUIDsForTest.isEmpty)
    }
}
