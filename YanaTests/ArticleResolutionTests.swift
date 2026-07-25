import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleResolution")
struct ArticleResolutionTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func makeContext() throws -> ModelContext {
        return ModelContext(try makeContainer())
    }

    @Test func fetchByIdentifierFindsArticle() async throws {
        let context = try makeContext()
        context.insert(Article(title: "t", identifier: "wanted", url: "u"))
        try context.save()
        #expect(ArticleResolution.fetchByIdentifier("wanted", in: context)?.identifier == "wanted")
    }

    @Test func fetchByIdentifierReturnsNilForUnknown() async throws {
        let context = try makeContext()
        #expect(ArticleResolution.fetchByIdentifier("missing", in: context) == nil)
    }

    @Test func resolveUsesPersistentIDFastPath() async throws {
        let context = try makeContext()
        let article = Article(title: "t", identifier: "live", url: "u")
        context.insert(article)
        try context.save()
        let summary = ArticleSummary(article)   // carries a live persistentID
        #expect(ArticleResolution.resolve(summary, in: context)?.identifier == "live")
    }

    @Test func resolveFallsBackToIdentifierWhenPersistentIDNil() async throws {
        let context = try makeContext()
        let article = Article(title: "t", identifier: "rehydrated", url: "u")
        context.insert(article)
        try context.save()

        // A cache-rehydrated summary has no persistentID: encode → decode drops it.
        let data = try PropertyListEncoder().encode([ArticleSummary(article)])
        let decoded = try PropertyListDecoder().decode([ArticleSummary].self, from: data)
        let summary = try #require(decoded.first)
        #expect(summary.persistentID == nil)
        #expect(ArticleResolution.resolve(summary, in: context)?.identifier == "rehydrated")
    }

    @Test func resolveSeesBackgroundUpdatedBody() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        main.insert(feed)
        let article = Article(title: "OLD", identifier: "id1", url: "u", date: .now, author: "", iconURL: nil)
        article.feed = feed
        article.blocks = BlockParser.blocks(fromHTML: "<p>old</p>", baseURL: nil)
        main.insert(article); try main.save()
        let summary = ArticleSummary(article)

        // Simulate a background aggregation write via a sibling context (mirrors the writer path).
        let sibling = ModelContext(container)
        if let a = sibling.model(for: article.persistentModelID) as? Article {
            a.blocks = BlockParser.blocks(fromHTML: "<p>new body</p>", baseURL: nil)
            try sibling.save()
        }

        let resolved = ArticleResolution.resolve(summary, in: main)
        #expect(resolved?.plainText.contains("new body") == true)
    }

    /// `Article.identifier` is a per-feed dedup key, not globally unique: two feeds can hold
    /// articles with the same identifier. Resolving a summary must pin the exact article via its
    /// `persistentModelID`, never resolve the wrong feed's article by an unscoped identifier fetch.
    @Test func resolveDisambiguatesCrossFeedIdentifierCollision() async throws {
        let context = try makeContext()

        let feedA = Feed(name: "A", aggregatorType: .feedContent, identifier: "A")
        let feedB = Feed(name: "B", aggregatorType: .feedContent, identifier: "B")
        context.insert(feedA); context.insert(feedB)

        let articleA = Article(title: "Title A", identifier: "shared-id", url: "uA")
        articleA.feed = feedA
        articleA.blocks = BlockParser.blocks(fromHTML: "<p>body A</p>", baseURL: nil)
        let articleB = Article(title: "Title B", identifier: "shared-id", url: "uB")
        articleB.feed = feedB
        articleB.blocks = BlockParser.blocks(fromHTML: "<p>body B</p>", baseURL: nil)
        context.insert(articleA); context.insert(articleB)
        try context.save()

        // Summary points at feed B's article via its live persistentID.
        let summaryB = ArticleSummary(articleB)
        let resolved = ArticleResolution.resolve(summaryB, in: context)
        #expect(resolved?.feed?.identifier == "B")
        #expect(resolved?.title == "Title B")
    }
}
