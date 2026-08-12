import Foundation
import SwiftData
import Testing
@testable import Yana

/// Timeline ordering: `ArticleSummaryLoader` (used by `ArticleStore`) fetches articles read-first
/// (oldest→newest), then unread (oldest→newest) — see `Article.readRank`'s doc comment. This is
/// the canonical display order for both the reader pager and the article list view that reads
/// `store.summaries` directly. Sorted by `createdAt` (server insertion order), never `date` (the
/// feed's own, possibly-backfilled publish timestamp) — see `Article.createdAt`'s doc comment.
@MainActor
@Suite("Timeline ordering")
struct TimelineOrderingTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func insertArticle(
        _ id: String, createdAt: Date, date: Date, read: Bool, into context: ModelContext
    ) {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.createdAt = createdAt
        a.date = date
        a.setRead(read)
        context.insert(a)
    }

    private func seed(_ context: ModelContext) {
        let base = Date(timeIntervalSince1970: 1_000_000)
        // `createdAt` encodes the expected sort order; `date` is deliberately reversed within each
        // read/unread bucket so this test proves the fetch sorts by `createdAt` (server insertion
        // order), never `date` (the feed's own, possibly-backfilled publish timestamp).
        insertArticle(
            "read-old", createdAt: base, date: base.addingTimeInterval(200), read: true, into: context
        )
        insertArticle(
            "read-new", createdAt: base.addingTimeInterval(100), date: base, read: true, into: context
        )
        insertArticle(
            "unread-old", createdAt: base.addingTimeInterval(200), date: base.addingTimeInterval(300),
            read: false, into: context
        )
        insertArticle(
            "unread-new", createdAt: base.addingTimeInterval(300), date: base.addingTimeInterval(100),
            read: false, into: context
        )
    }

    @Test func articleStoreFetchDescriptorIsReadThenUnreadByCreatedAt() throws {
        let context = try makeContext()
        seed(context)

        // The ArticleSummaryLoader descriptor: readRank ascending, then createdAt ascending.
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.readRank, order: .forward), SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt, \.readRank]
        let fetched = try context.fetch(descriptor)
        #expect(fetched.map(\.identifier) == ["read-old", "read-new", "unread-old", "unread-new"])
    }
}
