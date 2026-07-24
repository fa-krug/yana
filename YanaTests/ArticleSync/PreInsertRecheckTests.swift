import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Pre-insert re-check")
struct PreInsertRecheckTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config))
    }

    @Test("A new insert adopts the canonical createdAt when the sync layer knows the UID")
    func adoptsCanonical() throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let canonical = Date(timeIntervalSince1970: 12345)

        let aggregated = [AggregatedArticle(
            title: "T", identifier: "a1", url: "https://x/1", rawContent: "", content: "<p>hi</p>",
            date: Date(timeIntervalSince1970: 500), author: "", iconURL: nil)]

        let inserted = ArticleUpsert.apply(
            aggregated, to: feed, starredTag: nil, context: context, now: .now,
            jitter: { 60 },      // would back-date by 60s if canonical were absent
            canonicalCreatedAt: { uid in uid == "f1|feed_content|a1" ? canonical : nil })

        #expect(inserted == 1)
        let article = try #require(feed.articles.first)
        #expect(article.createdAt == canonical)     // canonical adopted, not now-60
    }

    @Test("Without a canonical hit the insert back-dates by jitter as before")
    func fallsBackToJitter() throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let now = Date(timeIntervalSince1970: 10_000)
        let aggregated = [AggregatedArticle(
            title: "T", identifier: "a2", url: "https://x/2", rawContent: "", content: "<p>hi</p>",
            date: now, author: "", iconURL: nil)]
        _ = ArticleUpsert.apply(aggregated, to: feed, starredTag: nil, context: context, now: now,
                                jitter: { 60 }, canonicalCreatedAt: { _ in nil })
        let article = try #require(feed.articles.first)
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

        let article = try #require(feed.articles.first)
        #expect(article.syncFeedIdentifier == "f1")
        #expect(article.syncAggregatorType == "feed_content")
    }
}
