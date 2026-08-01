import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Article starred-as-tag")
struct ArticleStarredTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func starringAddsBuiltInTagUnstarringRemovesIt() throws {
        let context = try makeContext()
        Yana.Tag.ensureBuiltIns(in: context)
        try context.save()
        let starred = try #require(try context.fetch(FetchDescriptor<Yana.Tag>(predicate: #Predicate { $0.isBuiltIn })).first)

        let article = Article(title: "P", identifier: "p1", url: "https://x.com/1")
        context.insert(article)

        #expect(article.isStarred == false)
        article.setStarred(true, using: starred)
        #expect(article.isStarred == true)
        article.setStarred(false, using: starred)
        #expect(article.isStarred == false)
    }
}
