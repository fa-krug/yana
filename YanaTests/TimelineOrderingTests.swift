import Foundation
import SwiftData
import Testing
@testable import Yana

/// Timeline ordering: the timeline mirrors the server's own append-only article sequence —
/// `createdAt` ascending (the server's insertion timestamp) with `serverID` breaking ties, and
/// nothing else. Read state is display-only and MUST NOT take part in the sort: an article changing
/// from unread to read used to move it from the "unread block" to the "read block", which shuffled
/// the list under the user mid-navigation (swiping forward then back landed on a different article
/// every time). See `TimelineOrder`.
@MainActor
@Suite("Timeline ordering")
struct TimelineOrderingTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @discardableResult
    private func insertArticle(
        _ id: String, createdAt: Date, date: Date, serverID: Int? = nil, read: Bool = false,
        into context: ModelContext
    ) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.createdAt = createdAt
        a.date = date
        a.serverID = serverID
        a.setRead(read)
        context.insert(a)
        return a
    }

    /// The `ArticleSummaryLoader` descriptor, restated here so a change to it has to be a
    /// deliberate change to this test too.
    private func timelineDescriptor() -> FetchDescriptor<Article> {
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward), SortDescriptor(\.serverID, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt, \.serverID]
        return descriptor
    }

    /// `date` is deliberately reversed relative to `createdAt` so this proves the fetch sorts by
    /// `createdAt` (the server's append-only insertion order), never `date` (the feed's own,
    /// possibly-backfilled publish timestamp).
    @Test func orderIsServerInsertionOrderRegardlessOfReadState() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_000_000)
        insertArticle("first", createdAt: base, date: base.addingTimeInterval(300),
                      serverID: 1, read: true, into: context)
        insertArticle("second", createdAt: base.addingTimeInterval(100), date: base.addingTimeInterval(200),
                      serverID: 2, into: context)
        insertArticle("third", createdAt: base.addingTimeInterval(200), date: base.addingTimeInterval(100),
                      serverID: 3, read: true, into: context)
        insertArticle("fourth", createdAt: base.addingTimeInterval(300), date: base,
                      serverID: 4, into: context)

        let fetched = try context.fetch(timelineDescriptor())
        #expect(fetched.map(\.identifier) == ["first", "second", "third", "fourth"])
    }

    /// The server stamps `createdAt` with whole-second precision (`unixepoch()`), so one aggregation
    /// run lands hundreds of articles on the *same* timestamp. Without `serverID` in the sort those
    /// ties have no defined order at all: SQLite may return them in any order, and it need not be the
    /// order `SummaryIndexMerge`/`TimelineOrder` use when splicing a row back in — which is how a
    /// single mark-as-read could reshuffle a whole batch.
    @Test func sameSecondCreatedAtIsBrokenByServerID() throws {
        let context = try makeContext()
        let sameSecond = Date(timeIntervalSince1970: 1_000_000)
        for id in [7, 3, 9, 1] {
            insertArticle("a\(id)", createdAt: sameSecond, date: sameSecond, serverID: id, into: context)
        }

        let fetched = try context.fetch(timelineDescriptor())
        #expect(fetched.map(\.serverID) == [1, 3, 7, 9])
    }

    /// The reported bug, at the source: marking an article read must not move it. With read state in
    /// the sort, reading "second" moved it ahead of "first", so swiping forward and then back landed
    /// somewhere else entirely.
    @Test func markingAnArticleReadDoesNotMoveIt() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<4 {
            insertArticle("a\(i)", createdAt: base.addingTimeInterval(Double(i) * 100),
                          date: base.addingTimeInterval(Double(i) * 100), serverID: i, into: context)
        }
        let before = try context.fetch(timelineDescriptor()).map(\.identifier)

        let second = try context.fetch(
            FetchDescriptor<Article>(predicate: #Predicate { $0.identifier == "a1" })
        ).first!
        second.setRead(true)
        try context.save()

        #expect(try context.fetch(timelineDescriptor()).map(\.identifier) == before)
    }

    /// Back/forward symmetry, expressed on the in-memory index the pager actually walks: reading an
    /// article (and splicing that change in, exactly as `ArticleStore` does) must leave every
    /// article's neighbors untouched, so "swipe forward, swipe back" returns where it started.
    @Test func navigationIsSymmetricAfterMarkingReadThroughASplice() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_000_000)
        var articles: [Article] = []
        for i in 0..<5 {
            articles.append(
                insertArticle("a\(i)", createdAt: base.addingTimeInterval(Double(i) * 100),
                              date: base.addingTimeInterval(Double(i) * 100), serverID: i, into: context)
            )
        }
        try context.save()
        let index = articles.map { ArticleSummary($0) }

        // Swipe forward from a2 to a3: a3 becomes current and is marked read.
        articles[3].setRead(true)
        try context.save()
        let spliced = SummaryIndexMerge.apply(
            to: index, changed: [ArticleSummary(articles[3])], removed: []
        )

        #expect(spliced.map(\.identifier) == index.map(\.identifier))
        // Swiping back from a3 must land on a2 again.
        let currentIndex = TimelinePageIndex.index(of: "a3", serverID: 3, in: spliced)
        #expect(currentIndex == 3)
        #expect(spliced[currentIndex! - 1].identifier == "a2")
        #expect(spliced[currentIndex! + 1].identifier == "a4")
    }
}
