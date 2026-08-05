import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("SwiftData Models")
struct ModelTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: Feed.self, Yana.Tag.self, Article.self,
            configurations: config
        )
        return ModelContext(container)
    }

    @Test func insertAndFetchFeed() throws {
        let context = try makeContext()
        let feed = Feed(name: "Swift Blog", aggregator: "feedContent", identifier: "https://swift.org/atom.xml")
        context.insert(feed)
        try context.save()

        let feeds = try context.fetch(FetchDescriptor<Feed>())
        #expect(feeds.count == 1)
        #expect(feeds.first?.name == "Swift Blog")
        #expect(feeds.first?.aggregator == "feedContent")
    }

    @Test func deletingFeedCascadesToArticles() throws {
        let context = try makeContext()
        let feed = Feed(name: "F", aggregator: "feedContent", identifier: "https://x.com/feed")
        let article = Article(
            title: "Post", identifier: "https://x.com/1", url: "https://x.com/1",
            date: .now, author: "A"
        )
        article.feed = feed
        context.insert(feed)
        context.insert(article)
        try context.save()

        context.delete(feed)
        try context.save()

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.isEmpty)
    }
}
