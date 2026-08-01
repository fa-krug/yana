import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Article upsert identity")
struct ArticleUpsertIdentityTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config))
    }

    @Test("A new insert back-dates by the import jitter")
    func backDatesByJitter() throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let now = Date(timeIntervalSince1970: 10_000)
        let aggregated = [AggregatedArticle(
            title: "T", identifier: "a2", url: "https://x/2", rawContent: "", content: "<p>hi</p>",
            date: now, author: "", iconURL: nil)]
        _ = ArticleUpsert.apply(aggregated, to: feed, starredTag: nil, context: context, now: now,
                                jitter: { 60 })
        let article = try #require(feed.articles?.first)
        #expect(article.createdAt == now.addingTimeInterval(-60))
    }

    @Test("A freshly upserted article carries its origin feed identity")
    func populatesFeedIdentityOnInsert() throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let aggregated = [AggregatedArticle(
            title: "T", identifier: "a3", url: "https://x/3", rawContent: "", content: "<p>hi</p>",
            date: .now, author: "", iconURL: nil)]

        _ = ArticleUpsert.apply(aggregated, to: feed, starredTag: nil, context: context, now: .now)

        let article = try #require(feed.articles?.first)
        #expect(article.syncFeedIdentifier == "f1")
        #expect(article.syncAggregatorType == "feed_content")
    }
}
