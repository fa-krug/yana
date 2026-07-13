import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("SummaryIndexCache")
struct SummaryIndexCacheTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func makeSummary(_ id: String, in context: ModelContext) throws -> ArticleSummary {
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f-\(id)")
        let article = Article(title: id, identifier: id, url: id)
        article.feed = feed
        context.insert(feed); context.insert(article)
        try context.save()
        return ArticleSummary(article)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-test-\(UUID().uuidString).plist")
    }

    @Test func roundTripsSummariesWithoutPersistentID() async throws {
        let context = try makeContext()
        let summaries = [try makeSummary("a", in: context), try makeSummary("b", in: context)]
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = SummaryIndexCache(fileURL: url)
        await cache.save(summaries)
        let loaded = await cache.load()

        #expect(loaded?.map(\.identifier) == ["a", "b"])
        #expect(loaded?.first?.feedName == "Acme")
        #expect(loaded?.first?.persistentID == nil)   // runtime-only; never persisted
    }

    @Test func loadReturnsNilWhenAbsent() async throws {
        let cache = SummaryIndexCache(fileURL: tempURL())
        let loaded = await cache.load()
        #expect(loaded == nil)
    }

    @Test func loadReturnsNilWhenCorrupt() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a plist".utf8).write(to: url)

        let cache = SummaryIndexCache(fileURL: url)
        let loaded = await cache.load()
        #expect(loaded == nil)
    }
}
