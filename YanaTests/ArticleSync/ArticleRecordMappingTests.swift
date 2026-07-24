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

    @Test("apply stores the feed identity on the created article")
    func applyStoresIdentity() throws {
        let context = try makeContext()
        let feed = makeFeed(context)   // identifier "feed-1", aggregatorType .feedContent
        let record = SyncedArticleRecord(
            uid: "feed-1|feed_content|a-5", feedIdentifier: "feed-1", aggregatorType: "feed_content",
            articleIdentifier: "a-5", title: "Five", url: "https://x/5", author: "", summary: "",
            plainText: "", leadImageRef: "", iconURL: nil, date: .now, createdAt: .now, blockData: Data(),
            isStarred: false, tagNames: [], imageHashes: [])
        let article = ArticleRecordApply.apply(record, into: context, starredTag: nil,
                                               feedsByKey: ["feed-1|feed_content": feed])
        #expect(article.syncFeedIdentifier == "feed-1")
        #expect(article.syncAggregatorType == "feed_content")
    }

    @Test("Two unlinked feeds with a colliding identifier stay separate")
    func unlinkedCollisionStaysSeparate() throws {
        let context = try makeContext()
        func rec(_ feed: String) -> SyncedArticleRecord {
            SyncedArticleRecord(
                uid: "\(feed)|feed_content|dup", feedIdentifier: feed, aggregatorType: "feed_content",
                articleIdentifier: "dup", title: "from \(feed)", url: "https://x/dup", author: "", summary: "",
                plainText: "", leadImageRef: "", iconURL: nil, date: .now, createdAt: .now, blockData: Data(),
                isStarred: false, tagNames: [], imageHashes: [])
        }
        let a = ArticleRecordApply.apply(rec("feed-A"), into: context, starredTag: nil, feedsByKey: [:])
        try context.save()   // persist so the second apply's fetch can see the first
        let b = ArticleRecordApply.apply(rec("feed-B"), into: context, starredTag: nil, feedsByKey: [:])
        #expect(a !== b)
        let all = try context.fetch(FetchDescriptor<Article>())
        #expect(all.count == 2)
        #expect(a.title == "from feed-A")
        #expect(b.title == "from feed-B")
        #expect(a.syncFeedIdentifier == "feed-A")
        #expect(b.syncFeedIdentifier == "feed-B")
    }

    @Test("ArticleUID.make(for:) derives the UID from stored identity even when unlinked")
    func uidFromStoredIdentity() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "a-1", url: "https://x/1")
        article.syncFeedIdentifier = "feed-1"
        article.syncAggregatorType = "feed_content"
        context.insert(article)
        #expect(ArticleUID.make(for: article) == "feed-1|feed_content|a-1")
    }
}
