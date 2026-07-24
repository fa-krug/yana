import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSummary")
struct ArticleSummaryTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func mapsArticleFieldsTagsAndStar() throws {
        let context = try makeContext()
        let starred = Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true)
        let news = Yana.Tag(name: "News")
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f")
        let article = Article(title: "Hello", identifier: "a1", url: "u",
                              date: .now, author: "Ada")
        article.feed = feed
        article.tags = [news, starred]
        context.insert(feed); context.insert(article)
        try context.save()

        let summary = ArticleSummary(article)

        #expect(summary.identifier == "a1")
        #expect(summary.title == "Hello")
        #expect(summary.feedName == "Acme")
        #expect(summary.author == "Ada")
        #expect(summary.tagNames == ["News", Yana.Tag.starredName])
        #expect(summary.isStarred == true)
        #expect(summary.id == "a1")
        #expect(summary.persistentID == article.persistentModelID)
    }

    @Test func summaryConformsToFilterAndIdentityProtocols() throws {
        let context = try makeContext()
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f")
        let article = Article(title: "T", identifier: "a2", url: "u")
        article.feed = feed
        article.tags = [Yana.Tag(name: "Tech")]
        context.insert(feed); context.insert(article)
        let summary = ArticleSummary(article)

        #expect(summary.filterFeedName == "Acme")
        #expect(summary.filterTagNames == ["Tech"])
        #expect((summary as TimelineIdentifiable).identifier == "a2")
    }

    @Test func uidIsCollisionFreeAcrossFeeds() throws {
        let context = try makeContext()
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f1")
        let article = Article(title: "Hello", identifier: "a1", url: "u")
        article.feed = feed
        context.insert(feed); context.insert(article)
        try context.save()

        let summary = ArticleSummary(article)

        #expect(summary.uid == "f1|feed_content|a1")
    }
}
