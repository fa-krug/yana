import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleStore")
struct ArticleStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func tempCache() -> SummaryIndexCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-test-\(UUID().uuidString).plist")
        return SummaryIndexCache(fileURL: url)
    }

    private func insertArticle(_ id: String, into context: ModelContext, date: Date, serverID: Int? = nil) {
        let feed = Feed(name: "Acme", aggregator: "feedContent", identifier: "f-\(id)-\(serverID.map(String.init) ?? "x")")
        let article = Article(title: id, identifier: id, url: id)
        article.feed = feed
        article.date = date
        article.createdAt = date
        article.serverID = serverID
        context.insert(feed); context.insert(article)
    }

    private func seed(_ count: Int, into context: ModelContext) {
        for i in 0..<count {
            insertArticle("a\(i)", into: context, date: Date(timeIntervalSince1970: TimeInterval(i + 1)))
        }
    }

    @Test func loadsExistingArticlesChronologically() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("old", into: context, date: Date(timeIntervalSince1970: 1))
        insertArticle("new", into: context, date: Date(timeIntervalSince1970: 2))
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

        insertArticle("x", into: container.mainContext, date: .now)
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
        insertArticle("cached", into: cachedContext, date: .now)
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
            anchorProvider: { ("a50", nil) }
        )
        await store.bootstrap()

        #expect(store.hasLoaded == true)
        #expect(store.summaries.count == 100)
        #expect(store.summaries.first?.identifier == "a0")
        #expect(store.summaries.last?.identifier == "a99")
    }

    @Test func publishFastDatasetServesWindowWithoutReconcile() async throws {
        let container = try makeContainer()
        seed(100, into: container.mainContext)            // a0…a99
        try container.mainContext.save()

        let store = ArticleStore(
            container: container,
            cache: tempCache(),                           // cold cache → anchor window path
            anchorProvider: { ("a50", nil) }
        )
        await store.publishFastDataset()

        #expect(store.hasLoaded == true)
        #expect(store.summaries.count == 51)              // 2*radius+1, NOT the full 100
        #expect(store.summaries.first?.identifier == "a25")
        #expect(store.summaries.last?.identifier == "a75")
    }

    /// `identifier` is only a per-feed dedup key -- two different feeds can share the same source
    /// URL. The cold-cache anchor window must center on the anchor's `serverID` when one is known,
    /// not on whichever same-identifier row the (unsorted-by-recency) identifier match happens to
    /// resolve to first -- otherwise the very first frame after a cold launch could be built around
    /// a completely different article's neighborhood.
    @Test func publishFastDatasetWindowDisambiguatesArticlesThatShareAnIdentifierAcrossFeeds() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        seed(100, into: context)                                          // a0…a99, dates 1…100
        insertArticle("dup", into: context, date: Date(timeIntervalSince1970: 10), serverID: 201)  // near a9
        insertArticle("dup", into: context, date: Date(timeIntervalSince1970: 90), serverID: 202)  // near a89
        try context.save()

        let store = ArticleStore(
            container: container,
            cache: tempCache(),                           // cold cache → anchor window path
            anchorProvider: { ("dup", 202) }               // the serverID-202 copy, near a89
        )
        await store.publishFastDataset()

        #expect(store.hasLoaded == true)
        #expect(store.summaries.contains { $0.serverID == 202 })
        // Centered near date 90 (a64…a99), not near date 10 (which the identifier-only match --
        // picking whichever "dup" row sorts first by createdAt -- would have wrongly resolved to).
        #expect(store.summaries.first?.identifier == "a64")
        #expect(store.summaries.last?.identifier == "a99")
    }
}
