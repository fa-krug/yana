import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleStore")
struct ArticleStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func tempCache() -> SummaryIndexCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-test-\(UUID().uuidString).plist")
        return SummaryIndexCache(fileURL: url)
    }

    private func insertArticle(_ id: String, into context: ModelContext, createdAt: Date) {
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f-\(id)")
        let article = Article(title: id, identifier: id, url: id)
        article.feed = feed
        article.createdAt = createdAt
        context.insert(feed); context.insert(article)
    }

    private func seed(_ count: Int, into context: ModelContext) {
        for i in 0..<count {
            insertArticle("a\(i)", into: context, createdAt: Date(timeIntervalSince1970: TimeInterval(i + 1)))
        }
    }

    @Test func loadsExistingArticlesChronologically() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("old", into: context, createdAt: Date(timeIntervalSince1970: 1))
        insertArticle("new", into: context, createdAt: Date(timeIntervalSince1970: 2))
        try context.save()

        let store = ArticleStore(container: container, cache: tempCache())
        await store.refreshNow()

        #expect(store.hasLoaded == true)
        #expect(store.summaries.map(\.identifier) == ["old", "new"])
    }

    @Test func reflectsInsertOnRefresh() async throws {
        let container = try makeContainer()
        let store = ArticleStore(container: container, cache: tempCache())
        await store.refreshNow()
        #expect(store.summaries.isEmpty)

        insertArticle("x", into: container.mainContext, createdAt: .now)
        try container.mainContext.save()
        await store.refreshNow()

        #expect(store.summaries.map(\.identifier) == ["x"])
    }

    @Test func bootstrapServesCacheThenReconcilesToDB() async throws {
        let container = try makeContainer()
        seed(3, into: container.mainContext)             // DB has a0,a1,a2
        try container.mainContext.save()

        // Pre-seed the cache with a DIFFERENT id so we can tell the paths apart.
        let cache = tempCache()
        let cachedContainer = try makeContainer()
        let cachedContext = ModelContext(cachedContainer)
        insertArticle("cached", into: cachedContext, createdAt: .now)
        try cachedContext.save()
        let cachedSummary = ArticleSummary(
            try #require(cachedContext.fetch(FetchDescriptor<Article>()).first)
        )
        await cache.save([cachedSummary])

        let store = ArticleStore(container: container, cache: cache)
        await store.bootstrap()

        #expect(store.hasLoaded == true)
        #expect(store.summaries.map(\.identifier) == ["a0", "a1", "a2"])   // reconciled to DB
    }

    @Test func bootstrapUsesAnchorWindowWhenCacheCold() async throws {
        let container = try makeContainer()
        seed(100, into: container.mainContext)
        try container.mainContext.save()

        let store = ArticleStore(
            container: container,
            cache: tempCache(),                          // empty → cold cache
            anchorProvider: { "a50" }
        )
        await store.bootstrap()

        #expect(store.hasLoaded == true)
        #expect(store.summaries.count == 100)
        #expect(store.summaries.first?.identifier == "a0")
        #expect(store.summaries.last?.identifier == "a99")
    }
}
