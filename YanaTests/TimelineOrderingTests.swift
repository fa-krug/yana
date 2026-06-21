import Foundation
import SwiftData
import Testing
@testable import Yana

/// The timeline reads oldest → newest: in the reader, left is old and right is new; in the
/// article list, top is old and bottom is new. Both surfaces share the same ascending
/// `createdAt` sort, so a single ordering contract covers them.
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

    @Test func readerDescriptorSortsOldestFirst() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_000_000)
        insertArticle("new", createdAt: base.addingTimeInterval(200), into: context)
        insertArticle("old", createdAt: base, into: context)
        insertArticle("mid", createdAt: base.addingTimeInterval(100), into: context)

        let fetched = try context.fetch(ReaderScreen.timelineDescriptor)
        // Index 0 is the leftmost page; it must be the oldest article.
        #expect(fetched.map(\.identifier) == ["old", "mid", "new"])
    }

    @Test func articleListDescriptorSortsOldestFirst() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_000_000)
        insertArticle("new", createdAt: base.addingTimeInterval(200), into: context)
        insertArticle("old", createdAt: base, into: context)
        insertArticle("mid", createdAt: base.addingTimeInterval(100), into: context)

        let fetched = try context.fetch(ArticleListView.timelineDescriptor)
        // Row 0 is the top of the list; it must be the oldest article.
        #expect(fetched.map(\.identifier) == ["old", "mid", "new"])
    }
}
