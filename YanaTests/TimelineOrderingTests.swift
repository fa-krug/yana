import Foundation
import SwiftData
import Testing
@testable import Yana

/// Timeline ordering: `ArticleSummaryLoader` (used by `ArticleStore`) fetches articles read-first
/// (oldest→newest), then unread (oldest→newest) — see `Article.readRank`'s doc comment. This is
/// the canonical display order for both the reader pager and the article list view that reads
/// `store.summaries` directly.
@MainActor
@Suite("Timeline ordering")
struct TimelineOrderingTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func insertArticle(_ id: String, date: Date, read: Bool, into context: ModelContext) {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.date = date
        a.setRead(read)
        context.insert(a)
    }

    private func seed(_ context: ModelContext) {
        let base = Date(timeIntervalSince1970: 1_000_000)
        // Unread, newest by date -- must still sort AFTER every read article.
        insertArticle("unread-new", date: base.addingTimeInterval(300), read: false, into: context)
        // Read, oldest by date -- must sort first overall.
        insertArticle("read-old", date: base, read: true, into: context)
        // Unread, oldest unread -- must sort right after the read block.
        insertArticle("unread-old", date: base.addingTimeInterval(100), read: false, into: context)
        // Read, newest read -- must sort right before the unread block.
        insertArticle("read-new", date: base.addingTimeInterval(200), read: true, into: context)
    }

    @Test func articleStoreFetchDescriptorIsReadThenUnreadByDate() throws {
        let context = try makeContext()
        seed(context)

        // The ArticleSummaryLoader descriptor: readRank ascending, then date ascending.
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.readRank, order: .forward), SortDescriptor(\.date, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt, \.readRank]
        let fetched = try context.fetch(descriptor)
        #expect(fetched.map(\.identifier) == ["read-old", "read-new", "unread-old", "unread-new"])
    }
}
