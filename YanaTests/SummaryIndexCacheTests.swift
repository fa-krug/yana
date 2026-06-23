import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("SummaryIndexCache")
struct SummaryIndexCacheTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func makeSummary(_ id: String, in context: ModelContext) throws -> ArticleSummary {
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f-\(id)")
        let article = Article(title: id, identifier: id, url: id)
        article.feed = feed
        context.insert(feed); context.insert(article)
        try context.save()   // permanent persistentModelID so the Codable round-trip is stable
        return ArticleSummary(article)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-test-\(UUID().uuidString).plist")
    }

    @Test func roundTripsSummaries() async throws {
        let context = try makeContainer().mainContext
        let summaries = [try makeSummary("a", in: context), try makeSummary("b", in: context)]
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = SummaryIndexCache(fileURL: url)
        await cache.save(summaries)
        let loaded = await cache.load()

        #expect(loaded?.map(\.identifier) == ["a", "b"])
        #expect(loaded?.first?.feedName == "Acme")
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
