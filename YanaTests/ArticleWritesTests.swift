import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleWrites")
struct ArticleWritesTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func markReadIsANoOpWhenAlreadyRead() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id", url: "https://x.com/1")
        article.read = true
        context.insert(article)
        try context.save()

        ArticleWrites.markRead(article, modelContext: context)
        #expect(article.read == true)   // still true; no crash, no duplicate work observable here
    }

    @Test func markReadSetsReadLocallyWhenNotPaired() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id", url: "https://x.com/1")
        // No serverID set -- matches an article that hasn't been through sync, or a device that
        // isn't paired. `ArticleWrites.markRead` must still flip the local flag.
        context.insert(article)
        try context.save()

        ArticleWrites.markRead(article, modelContext: context)
        #expect(article.read == true)
    }

    @Test func toggleStarFlipsLocallyWhenNotPaired() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id", url: "https://x.com/1")
        context.insert(article)
        try context.save()

        ArticleWrites.toggleStar(article, modelContext: context)
        #expect(article.starred == true)
        ArticleWrites.toggleStar(article, modelContext: context)
        #expect(article.starred == false)
    }
}
