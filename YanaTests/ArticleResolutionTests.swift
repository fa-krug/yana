import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleResolution")
struct ArticleResolutionTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
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
}
