import Testing
import SwiftData
import Foundation
@testable import Yana

@MainActor
@Suite("ArticleListFilter")
struct ArticleListFilterTests {
    /// Mirrors ArticleListView.results: search → TagFilter → FeedFilter, using the same
    /// AppSettings-backed filter values the reader uses. The list's results must be a subset
    /// of the reader's filtered timeline so a tapped article always resolves to an index.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Article.self, Feed.self, Tag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    @Test func listResultsAreSubsetAndJumpResolves() throws {
        let ctx = try makeContext()
        let feedA = Feed(name: "Alpha", aggregator: "feedContent", identifier: "a")
        let feedB = Feed(name: "Beta", aggregator: "feedContent", identifier: "b")
        ctx.insert(feedA); ctx.insert(feedB)
        let a1 = Article(title: "Alpha one", identifier: "a1", url: "https://a/1")
        let a2 = Article(title: "Beta two", identifier: "b2", url: "https://b/2")
        ctx.insert(a1); ctx.insert(a2)
        a1.feed = feedA
        a2.feed = feedB
        let all = [a1, a2]

        // Reader filter: disable feed "Beta".
        let disabledFeeds: Set<String> = ["Beta"]

        // Reader's filtered timeline (no search).
        let readerFiltered = FeedFilter.apply(
            to: TagFilter.apply(to: all, disabledTagNames: [], includeUntagged: true),
            disabledFeedNames: disabledFeeds
        )
        // List results (same filter + a matching search).
        let listResults = FeedFilter.apply(
            to: TagFilter.apply(
                to: ArticleSearch.filter(all, query: "Alpha"),
                disabledTagNames: [], includeUntagged: true),
            disabledFeedNames: disabledFeeds
        )

        #expect(readerFiltered.map(\.identifier) == ["a1"])
        #expect(listResults.map(\.identifier) == ["a1"])
        // A tapped list article resolves to an index in the reader's filtered timeline.
        #expect(TimelinePageIndex.index(of: "a1", in: readerFiltered) == 0)
        // An article filtered out of the reader's timeline resolves to nil (no jump).
        #expect(TimelinePageIndex.index(of: "b2", in: readerFiltered) == nil)
    }

    /// Mirrors `ArticleListView.results`'s browsing-mode chain (no search active): the currently-
    /// open article, even once marked read, must stay ahead of the still-unread rows instead of
    /// jumping to the back of the read block the instant the list is opened.
    /// "b" is read and pinned (the article currently being browsed). "d" is a second, unpinned
    /// read article -- exercising a real multi-row read block, not the degenerate single-read-row
    /// case that would pass under either the correct or the previously-inverted algorithm. Input is
    /// built directly in true canonical (readRank, createdAt) order -- `createdAt`, not `date`, is
    /// the timeline's real secondary sort/reinsertion key (see `TimelineOrder`'s doc comment): the
    /// read block first (oldest to newest: "b" createdAt 2, "d" createdAt 3), then the unread block
    /// (oldest to newest: "a" createdAt 1, "c" createdAt 4) -- `TagFilter`/`FeedFilter`/
    /// `StarredFilter` only filter, they never reorder, so feeding them anything else would not
    /// reflect what `ArticleStore` actually hands the pinning step.
    @Test func currentArticlePinnedAheadOfReadBlockWhenBrowsing() throws {
        let ctx = try makeContext()
        let feed = Feed(name: "Alpha", aggregator: "feedContent", identifier: "f")
        ctx.insert(feed)
        let b = Article(title: "b", identifier: "b", url: "https://x/b")
        b.createdAt = Date(timeIntervalSince1970: 2); b.feed = feed; b.setRead(true)
        let d = Article(title: "d", identifier: "d", url: "https://x/d")
        d.createdAt = Date(timeIntervalSince1970: 3); d.feed = feed; d.setRead(true)
        let a = Article(title: "a", identifier: "a", url: "https://x/a")
        a.createdAt = Date(timeIntervalSince1970: 1); a.feed = feed
        let c = Article(title: "c", identifier: "c", url: "https://x/c")
        c.createdAt = Date(timeIntervalSince1970: 4); c.feed = feed
        ctx.insert(a); ctx.insert(b); ctx.insert(c); ctx.insert(d)

        let byTag = TagFilter.apply(to: [b, d, a, c], disabledTagNames: [], includeUntagged: true)
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: [])
        let canonical = StarredFilter.apply(to: byFeed, starredOnly: false)
        let pinned = TimelinePinning.apply(to: canonical, pinning: "b")

        #expect(pinned.map(\.identifier) == ["d", "a", "b", "c"])
    }
}
