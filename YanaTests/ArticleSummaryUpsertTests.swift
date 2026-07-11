import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
struct ArticleSummaryUpsertTests {
    private func context() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Article.self, Tag.self, configurations: config)
        return ModelContext(container)
    }

    @Test func insertCopiesSummary() throws {
        let ctx = try context()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "")
        ctx.insert(feed)
        let agg = AggregatedArticle(title: "T", identifier: "id1", url: "https://e.com/1",
                                    rawContent: "", content: "<p>body</p>", date: .now,
                                    author: "", iconURL: nil, summary: "the summary")
        _ = ArticleUpsert.apply([agg], to: feed, starredTag: nil, context: ctx, now: .now)
        #expect(feed.articles.first?.summary == "the summary")
    }

    @Test func updateRefreshesSummary() throws {
        let ctx = try context()
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "")
        ctx.insert(feed)
        let v1 = AggregatedArticle(title: "T", identifier: "id1", url: "u", rawContent: "",
                                   content: "c", date: .now, author: "", iconURL: nil, summary: "s1")
        _ = ArticleUpsert.apply([v1], to: feed, starredTag: nil, context: ctx, now: .now)
        let v2 = AggregatedArticle(title: "T", identifier: "id1", url: "u", rawContent: "",
                                   content: "c", date: .now, author: "", iconURL: nil, summary: "s2")
        _ = ArticleUpsert.apply([v2], to: feed, starredTag: nil, context: ctx, now: .now)
        #expect(feed.articles.count == 1)
        #expect(feed.articles.first?.summary == "s2")
    }
}
