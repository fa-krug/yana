import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSummaryLoader.loadWindow")
struct ArticleSummaryLoaderTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func seed(_ count: Int, into context: ModelContext) {
        let feed = Feed(name: "Acme", aggregator: "feedContent", identifier: "f")
        context.insert(feed)
        for i in 0..<count {
            let a = Article(title: "a\(i)", identifier: "a\(i)", url: "a\(i)")
            a.feed = feed
            a.date = Date(timeIntervalSince1970: TimeInterval(i + 1))
            context.insert(a)
        }
    }

    @Test func windowIsCenteredOnAnchorAndIncludesIt() async throws {
        let container = try makeContainer()
        seed(100, into: container.mainContext)
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        let window = try await loader.loadWindow(around: "a50", radius: 5)
        #expect(window.map(\.identifier) == ["a45","a46","a47","a48","a49","a50","a51","a52","a53","a54","a55"])
    }

    @Test func fallsBackToNewestWhenAnchorMissing() async throws {
        let container = try makeContainer()
        seed(10, into: container.mainContext)
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        let window = try await loader.loadWindow(around: "does-not-exist", radius: 2)
        #expect(window.map(\.identifier) == ["a5","a6","a7","a8","a9"])   // newest 2*2+1, ascending
    }

    @Test func fallsBackToNewestWhenAnchorNil() async throws {
        let container = try makeContainer()
        seed(4, into: container.mainContext)
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        let window = try await loader.loadWindow(around: nil, radius: 10)
        #expect(window.map(\.identifier) == ["a0","a1","a2","a3"])   // fewer than window: all, ascending
    }

    /// Finding 4: the anchor-relative window splits its `newer`/`older` fetches on `date`
    /// alone while `lightDescriptor` sorts on the compound `(readRank, date)` key, so a read
    /// row with a later `date` than the anchor can land in `newer` mixed with genuinely
    /// unread rows, and the naive `older.reversed() + newer` concatenation doesn't restore
    /// `(readRank, date)` order. Mark a handful of the *newest* articles read (so they carry
    /// late `date`s but should sort to the FRONT, not the back) and assert the window comes
    /// back read-block-then-unread-block, matching `SummaryIndexMerge`'s canonical ordering.
    @Test func windowStaysInCanonicalReadThenUnreadOrderWithMixedReadState() async throws {
        let container = try makeContainer()
        seed(20, into: container.mainContext)
        // Mark the newest few articles (by date) as read -- they'll have late timestamps but
        // must still sort ahead of unread rows in the assembled window.
        let descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.date, order: .forward)])
        let all = try container.mainContext.fetch(descriptor)
        for article in all.suffix(3) {
            article.setRead(true)
        }
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        // Anchor near the middle so both the `newer` and `older` fetches are exercised.
        let window = try await loader.loadWindow(around: "a10", radius: 8)

        // The window must be internally sorted (readRank, date) ascending: all read rows
        // before all unread rows, each block ascending by date.
        for i in 1..<window.count {
            let a = window[i - 1], b = window[i]
            if a.isRead != b.isRead {
                #expect(a.isRead && !b.isRead, "read rows must sort before unread rows")
            } else {
                #expect(a.date <= b.date, "same-read-state rows must stay date-ascending")
            }
        }
    }
}
