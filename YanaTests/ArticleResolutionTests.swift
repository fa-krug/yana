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
}
