import Foundation
import SwiftData
import Testing
@testable import Yana

/// The article-list view windows the *newest* page: its descriptor fetches by descending
/// `createdAt` so `fetchLimit` keeps the most-recent articles (an ascending sort would keep the
/// oldest, leaving the reader's current article outside a partial window). The view reverses the
/// fetch to display oldest → new — top = old. These tests pin that contract: a partial window must
/// keep the newest articles, and the natural fetch order is newest-first so reversing yields the
/// displayed oldest → new order.
///
/// (The reader timeline itself no longer uses a windowed descriptor — `ReaderScreen` is driven by
/// `ArticleStore`'s chronological `summaries` — so the former `ReaderScreen.timelineDescriptor`
/// tests were removed with that method.)
@MainActor
@Suite("Timeline ordering")
struct TimelineOrderingTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func insertArticle(_ id: String, createdAt: Date, into context: ModelContext) {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.createdAt = createdAt
        context.insert(a)
    }

    private func seed(_ context: ModelContext) {
        let base = Date(timeIntervalSince1970: 1_000_000)
        insertArticle("new", createdAt: base.addingTimeInterval(200), into: context)
        insertArticle("old", createdAt: base, into: context)
        insertArticle("mid", createdAt: base.addingTimeInterval(100), into: context)
    }

    @Test func articleListDescriptorFetchesNewestFirst() throws {
        let context = try makeContext()
        seed(context)

        let fetched = try context.fetch(ArticleListView.timelineDescriptor(limit: 100))
        #expect(fetched.map(\.identifier) == ["new", "mid", "old"])
        #expect(fetched.reversed().map(\.identifier) == ["old", "mid", "new"])
    }

    @Test func articleListDescriptorWindowKeepsNewest() throws {
        let context = try makeContext()
        seed(context)

        let fetched = try context.fetch(ArticleListView.timelineDescriptor(limit: 2))
        #expect(fetched.map(\.identifier) == ["new", "mid"])
    }
}
