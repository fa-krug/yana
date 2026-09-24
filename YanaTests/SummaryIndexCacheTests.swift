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
        let feed = Feed(name: "Acme", identifier: "f-\(id)")
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

    /// Every field survives the binary format, including the optional and set-valued ones and
    /// non-ASCII text -- the string table and the flag byte are where a hand-rolled codec goes wrong.
    @Test func binaryFormatRoundTripsEveryField() throws {
        let rows = [
            ArticleSummary(identifier: "https://example.com/ü/1", serverID: 42, title: "Grüße — 🚀",
                           feedName: "Heise", feedLogoHash: "abc123", author: "Jörg",
                           date: Date(timeIntervalSinceReferenceDate: 1_000.25),
                           createdAt: Date(timeIntervalSinceReferenceDate: 2_000.5),
                           tagNames: ["Tech", "News"], isStarred: true, isRead: false),
            ArticleSummary(identifier: "b", serverID: nil, title: "", feedName: "Heise",
                           feedLogoHash: nil, author: "", date: .distantPast, createdAt: .distantFuture,
                           tagNames: [], isStarred: false, isRead: true),
        ]
        let decoded = try #require(SummaryIndexCodec.decode(SummaryIndexCodec.encode(rows)))
        #expect(decoded == rows)
        #expect(SummaryIndexCodec.decode(SummaryIndexCodec.encode([])) == [])
    }

    /// A file cut short by a crash mid-write (or any foreign bytes) decodes as `nil`, never traps
    /// and never yields a partial index.
    @Test func truncatedDataDecodesAsNil() {
        let row = ArticleSummary(identifier: "a", serverID: 1, title: "A", feedName: "F",
                                 feedLogoHash: "h", author: "x", date: .now, createdAt: .now,
                                 tagNames: ["t"], isStarred: false, isRead: false)
        let data = SummaryIndexCodec.encode([row, row])
        for length in [0, 3, 8, 20, data.count / 2, data.count - 1] {
            #expect(SummaryIndexCodec.decode(data.prefix(length)) == nil, "length \(length)")
        }
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
