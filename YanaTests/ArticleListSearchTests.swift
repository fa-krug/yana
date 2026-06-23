import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleListSearch")
struct ArticleListSearchTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func insert(_ context: ModelContext, id: String, title: String, content: String, author: String) {
        let a = Article(title: title, identifier: id, url: id, content: content, author: author)
        context.insert(a)
    }

    @Test func matchesTitleContentAndAuthorCaseInsensitively() throws {
        let context = try makeContext()
        insert(context, id: "1", title: "Swift Concurrency", content: "<p>actors</p>", author: "Ada")
        insert(context, id: "2", title: "Cooking", content: "<p>pasta and SWIFT sauce</p>", author: "Bo")
        insert(context, id: "3", title: "Gardening", content: "<p>soil</p>", author: "swiftly Cy")
        try context.save()

        let predicate = ArticleListSearch.predicate(for: "swift")
        let results = try context.fetch(FetchDescriptor<Article>(predicate: predicate))

        #expect(Set(results.map(\.identifier)) == ["1", "2", "3"])
    }

    @Test func nonMatchExcluded() throws {
        let context = try makeContext()
        insert(context, id: "1", title: "Swift", content: "x", author: "Ada")
        insert(context, id: "2", title: "Rust", content: "y", author: "Bo")
        try context.save()

        let results = try context.fetch(FetchDescriptor<Article>(predicate: ArticleListSearch.predicate(for: "rust")))
        #expect(results.map(\.identifier) == ["2"])
    }

    @Test func matchesFeedName() throws {
        let context = try makeContext()
        let feed = Feed(name: "TechRadar", aggregatorType: .feedContent, identifier: "f1")
        context.insert(feed)
        let matched = Article(title: "Some Title", identifier: "a1", url: "https://example.com/a1", content: "x", author: "Ed")
        matched.feed = feed
        context.insert(matched)
        let unmatched = Article(title: "Other Title", identifier: "a2", url: "https://example.com/a2", content: "y", author: "Fay")
        context.insert(unmatched)
        try context.save()

        let results = try context.fetch(FetchDescriptor<Article>(predicate: ArticleListSearch.predicate(for: "techradar")))
        #expect(results.map(\.identifier) == ["a1"])
    }
}
