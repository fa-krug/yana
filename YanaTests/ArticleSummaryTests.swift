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

    /// Tag membership is a live join now, not a per-article snapshot: `Article.tags` (still on
    /// the model, but never populated by `SyncWriter`) is not read at all -- the name comes from
    /// resolving the feed's current `tagIDs` against a synced `Tag`'s `serverID`, exactly what
    /// `SyncWriter.syncTags`/`replaceFeeds` populate.
    @Test func mapsArticleFieldsTagsAndStar() throws {
        let context = try makeContext()
        let news = Yana.Tag(name: "News")
        news.serverID = 1
        let feed = Feed(name: "Acme", identifier: "f")
        feed.tagIDs = [1]
        let article = Article(title: "Hello", identifier: "a1", url: "u",
                              date: .now, author: "Ada")
        article.feed = feed
        article.starred = true
        context.insert(feed); context.insert(news); context.insert(article)
        try context.save()

        let tagMap = ArticleSummary.tagNameLookup(in: context)
        let summary = ArticleSummary(article, tagNamesByID: tagMap)

        #expect(summary.identifier == "a1")
        #expect(summary.title == "Hello")
        #expect(summary.feedName == "Acme")
        #expect(summary.author == "Ada")
        #expect(summary.tagNames == ["News"])
        #expect(summary.isStarred == true)
        #expect(summary.id == "a1")
        #expect(summary.persistentID == article.persistentModelID)
    }

    @Test func summaryConformsToFilterAndIdentityProtocols() throws {
        let context = try makeContext()
        let tech = Yana.Tag(name: "Tech")
        tech.serverID = 1
        let feed = Feed(name: "Acme", identifier: "f")
        feed.tagIDs = [1]
        let article = Article(title: "T", identifier: "a2", url: "u")
        article.feed = feed
        context.insert(feed); context.insert(tech); context.insert(article)

        let tagMap = ArticleSummary.tagNameLookup(in: context)
        let summary = ArticleSummary(article, tagNamesByID: tagMap)

        #expect(summary.filterFeedName == "Acme")
        #expect(summary.filterTagNames == ["Tech"])
        #expect((summary as TimelineIdentifiable).identifier == "a2")
    }

    @Test func isReadMirrorsArticleRead() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id-1", url: "https://x.com/1")
        article.read = true
        context.insert(article)
        try context.save()

        let summary = ArticleSummary(article)
        #expect(summary.isRead == true)
    }

    @Test func isReadRoundTripsThroughCoding() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id-2", url: "https://x.com/2")
        article.read = true
        context.insert(article)
        try context.save()

        let summary = ArticleSummary(article)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ArticleSummary.self, from: data)
        #expect(decoded.isRead == true)
    }

    /// `serverID` (mirroring `Article.serverID`) is what `ReadingPositionSync`/
    /// `ReaderAnchorController` resolve a pulled remote reading position against, without a
    /// separate SwiftData round-trip.
    @Test func serverIDMirrorsArticleServerID() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id-3", url: "https://x.com/3")
        article.serverID = 42
        context.insert(article)
        try context.save()

        let summary = ArticleSummary(article)
        #expect(summary.serverID == 42)
    }

    /// A cache entry written before `serverID` existed has no such key at all -- decoding it must
    /// produce `nil`, not fail the whole disk-cache load.
    @Test func serverIDDecodesToNilWhenMissingFromOlderCachedData() throws {
        let json = #"""
        {"identifier":"id-4","title":"T","feedName":"F","author":"","date":0,"createdAt":0,"tagNames":[],"isStarred":false,"isRead":false}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ArticleSummary.self, from: json)
        #expect(decoded.serverID == nil)
    }

    @Test func serverIDRoundTripsThroughCoding() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id-5", url: "https://x.com/5")
        article.serverID = 7
        context.insert(article)
        try context.save()

        let summary = ArticleSummary(article)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ArticleSummary.self, from: data)
        #expect(decoded.serverID == 7)
    }
}
