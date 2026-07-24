import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleRecordMapping")
struct ArticleRecordMappingTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func makeFeed(_ context: ModelContext) -> Feed {
        let feed = Feed(name: "Example", aggregatorType: .feedContent, identifier: "feed-1")
        context.insert(feed)
        return feed
    }

    @Test("Record built from an article carries the UID triple and image hashes")
    func fromArticle() throws {
        let context = try makeContext()
        let feed = makeFeed(context)
        let article = Article(title: "T", identifier: "a-1", url: "https://x/1")
        article.feed = feed
        article.blocks = [.image(ref: "yana-img://hash1", caption: [])]
        context.insert(article)

        let record = try #require(SyncedArticleRecord(article: article))
        // Feed.aggregatorType stores AggregatorType.feedContent's rawValue, which is "feed_content"
        // (snake_case), not the enum case's camelCase name.
        #expect(record.uid == "feed-1|feed_content|a-1")
        #expect(record.imageHashes == ["hash1"])
        #expect(record.leadImageRef == "yana-img://hash1")
    }

    @Test("Applying a new record creates a linked article")
    func applyNew() throws {
        let context = try makeContext()
        let feed = makeFeed(context)
        let record = SyncedArticleRecord(
            uid: "feed-1|feedContent|a-9", feedIdentifier: "feed-1", aggregatorType: "feedContent",
            articleIdentifier: "a-9", title: "Nine", url: "https://x/9", author: "", summary: "",
            plainText: "nine", leadImageRef: "", iconURL: nil,
            date: Date(timeIntervalSince1970: 500), createdAt: Date(timeIntervalSince1970: 400),
            blockData: Data(), isStarred: false, tagNames: [], imageHashes: []
        )
        let feedsByKey = ["feed-1|feedContent": feed]
        let article = ArticleRecordApply.apply(record, into: context, starredTag: nil, feedsByKey: feedsByKey)
        #expect(article.identifier == "a-9")
        #expect(article.feed === feed)
        #expect(article.createdAt == Date(timeIntervalSince1970: 400))
    }

    @Test("Applying an existing UID keeps createdAt (first-writer-wins) but updates the body")
    func applyExistingKeepsCreatedAt() throws {
        let context = try makeContext()
        let feed = makeFeed(context)
        let existing = Article(title: "Old", identifier: "a-9", url: "https://x/9")
        existing.feed = feed
        existing.createdAt = Date(timeIntervalSince1970: 100)
        context.insert(existing)

        let record = SyncedArticleRecord(
            uid: "feed-1|feedContent|a-9", feedIdentifier: "feed-1", aggregatorType: "feedContent",
            articleIdentifier: "a-9", title: "New", url: "https://x/9", author: "", summary: "",
            plainText: "new", leadImageRef: "", iconURL: nil,
            date: Date(timeIntervalSince1970: 500), createdAt: Date(timeIntervalSince1970: 999),
            blockData: Data(), isStarred: false, tagNames: [], imageHashes: []
        )
        let article = ArticleRecordApply.apply(record, into: context, starredTag: nil,
                                               feedsByKey: ["feed-1|feedContent": feed])
        #expect(article.title == "New")                                   // last-writer-wins body
        #expect(article.createdAt == Date(timeIntervalSince1970: 100))    // first-writer-wins
    }

    @Test("A record whose feed is not yet present is created unlinked")
    func applyUnlinkedWhenFeedMissing() throws {
        let context = try makeContext()
        let record = SyncedArticleRecord(
            uid: "feed-x|feedContent|a-1", feedIdentifier: "feed-x", aggregatorType: "feedContent",
            articleIdentifier: "a-1", title: "Orphan", url: "https://x/1", author: "", summary: "",
            plainText: "", leadImageRef: "", iconURL: nil,
            date: .now, createdAt: .now, blockData: Data(), isStarred: false, tagNames: [], imageHashes: []
        )
        let article = ArticleRecordApply.apply(record, into: context, starredTag: nil, feedsByKey: [:])
        #expect(article.feed == nil)
        #expect(article.identifier == "a-1")
    }
}
