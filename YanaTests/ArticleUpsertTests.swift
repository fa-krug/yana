import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleUpsert")
struct ArticleUpsertTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func aggregated(_ id: String, title: String = "T", content: String = "C", date: Date = .now) -> AggregatedArticle {
        AggregatedArticle(title: title, identifier: id, url: id, rawContent: "", content: content, date: date, author: "", iconURL: nil)
    }

    @Test func insertsNewArticleWithFeedTagSnapshot() throws {
        let context = try makeContext()
        let news = Yana.Tag(name: "News")
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "f")
        feed.tags = [news]
        context.insert(feed)

        ArticleUpsert.apply([aggregated("x1")], to: feed, starredTag: nil, context: context, now: .now)

        #expect(feed.articles.count == 1)
        #expect(feed.articles.first?.tags.map(\.name) == ["News"])
    }

    @Test func updatesExistingByIdentifierAndPreservesStar() throws {
        let context = try makeContext()
        let starred = Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true)
        let news = Yana.Tag(name: "News")
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "f")
        feed.tags = [news]
        context.insert(feed); context.insert(starred)

        // First import, then user stars it.
        ArticleUpsert.apply([aggregated("x1", content: "old")], to: feed, starredTag: starred, context: context, now: .now)
        let article = try #require(feed.articles.first)
        article.setStarred(true, using: starred)
        let originalCreatedAt = article.createdAt

        // Re-import the same identifier with new content.
        ArticleUpsert.apply([aggregated("x1", content: "new")], to: feed, starredTag: starred, context: context, now: .now.addingTimeInterval(60))

        #expect(feed.articles.count == 1)                 // no duplicate
        #expect(article.content == "new")                 // content refreshed
        #expect(article.isStarred)                         // star survived re-import
        #expect(article.tags.contains { $0.name == "News" })
        #expect(article.createdAt == originalCreatedAt)    // timeline position preserved
    }

    @Test func preservesOriginalDateOnReimport() throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "f")
        context.insert(feed)

        let published = Date(timeIntervalSince1970: 1_000_000)
        ArticleUpsert.apply([aggregated("x1", date: published)], to: feed, starredTag: nil, context: context, now: .now)
        let article = try #require(feed.articles.first)

        // Re-import with a different (e.g. "now" fallback) date must NOT move the article.
        ArticleUpsert.apply([aggregated("x1", date: .now)], to: feed, starredTag: nil, context: context, now: .now)
        #expect(article.date == published)
    }

    @Test func returnsCountOfNewlyInsertedOnly() throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "f")
        context.insert(feed)

        // First import: both are new.
        let firstCount = ArticleUpsert.apply([aggregated("x1"), aggregated("x2")], to: feed, starredTag: nil, context: context, now: .now)
        #expect(firstCount == 2)

        // Re-import x1 (update) + x3 (new) → only 1 newly inserted.
        let secondCount = ArticleUpsert.apply([aggregated("x1"), aggregated("x3")], to: feed, starredTag: nil, context: context, now: .now)
        #expect(secondCount == 1)
        #expect(feed.articles.count == 3)
    }
}
