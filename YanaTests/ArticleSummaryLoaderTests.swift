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

    /// The cold-start window must come back in the same canonical `(createdAt, serverID)` order the
    /// full load produces, with read state playing no part -- otherwise the first painted timeline
    /// would differ from the one that replaces it milliseconds later, visibly reshuffling under the
    /// user. Marks a scattered handful of rows read (including ones on both sides of the anchor,
    /// which is where a read/unread block split used to tear the window apart) and asserts the window
    /// stays a contiguous, insertion-ordered slice.
    @Test func windowStaysInCanonicalOrderWithMixedReadState() async throws {
        let container = try makeContainer()
        seed(20, into: container.mainContext)
        let all = try container.mainContext.fetch(
            FetchDescriptor<Article>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )
        for article in [all[2], all[9], all[11], all[18]] {
            article.setRead(true)
        }
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        // Anchor near the middle so both the `newer` and `older` fetches are exercised.
        let window = try await loader.loadWindow(around: "a10", radius: 8)

        #expect(window.map(\.identifier) == (2...18).map { "a\($0)" })
        for i in 1..<window.count {
            #expect(window[i - 1].createdAt <= window[i].createdAt, "window must stay insertion-ordered")
        }
    }
}
