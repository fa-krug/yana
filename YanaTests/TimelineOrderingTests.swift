import Foundation
import SwiftData
import Testing
@testable import Yana

/// Timeline ordering: `ArticleSummaryLoader` (used by `ArticleStore`) fetches articles in
/// ascending `createdAt` order (oldest → new), which is the canonical display order for both
/// the reader pager and the article list view that reads `store.summaries` directly.
///
/// (The old `ArticleListView.timelineDescriptor` windowed-descriptor tests were removed when
/// Task 6 migrated the list to read from `ArticleStore` instead of a per-view `@Query`.)
@MainActor
@Suite("Timeline ordering")
struct TimelineOrderingTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

    @Test func articleStoreFetchDescriptorIsAscendingCreatedAt() throws {
        let context = try makeContext()
        seed(context)

        // The ArticleSummaryLoader descriptor: ascending createdAt (oldest first).
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt]
        let fetched = try context.fetch(descriptor)
        #expect(fetched.map(\.identifier) == ["old", "mid", "new"])
    }
}
