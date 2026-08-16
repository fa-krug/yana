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
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Article.self, Feed.self, Tag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try makeContainer())
    }

    @Test func listResultsAreSubsetAndJumpResolves() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let feedA = Feed(name: "Alpha", identifier: "a")
        let feedB = Feed(name: "Beta", identifier: "b")
        ctx.insert(feedA); ctx.insert(feedB)
        let a1 = Article(title: "Alpha one", identifier: "a1", url: "https://a/1")
        let a2 = Article(title: "Beta two", identifier: "b2", url: "https://b/2")
        ctx.insert(a1); ctx.insert(a2)
        a1.feed = feedA
        a2.feed = feedB
        try ctx.save()
        let all = [a1, a2]

        // Reader filter: disable feed "Beta".
        let disabledFeeds: Set<String> = ["Beta"]

        // Reader's filtered timeline (no search).
        let readerFiltered = FeedFilter.apply(
            to: TagFilter.apply(to: all, disabledTagNames: [], includeUntagged: true),
            disabledFeedNames: disabledFeeds
        )
        // List results (same filter + a matching search).
        let searched = await ArticleSearch.searchSummaries(query: "Alpha", container: container)
        let listResults = FeedFilter.apply(
            to: TagFilter.apply(
                to: searched,
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

    /// Mirrors `ArticleListView.results`'s browsing-mode chain (no search active): the list shows the
    /// reader timeline's own order, untouched. `TagFilter`/`FeedFilter`/`StarredFilter` only remove
    /// rows, they never reorder, so a mixed-read-state input in canonical `(createdAt, serverID)`
    /// order must come back out in exactly that order -- read rows included, in place. This is the
    /// guard on the reported bug: the list used to lift the currently-open article out of its slot
    /// (and sort read rows into their own leading block), so the list and the pager disagreed about
    /// where an article was.
    @Test func browsingKeepsCanonicalOrderRegardlessOfReadState() throws {
        let ctx = try makeContext()
        let feed = Feed(name: "Alpha", identifier: "f")
        ctx.insert(feed)
        let a = Article(title: "a", identifier: "a", url: "https://x/a")
        a.createdAt = Date(timeIntervalSince1970: 1); a.feed = feed
        let b = Article(title: "b", identifier: "b", url: "https://x/b")
        b.createdAt = Date(timeIntervalSince1970: 2); b.feed = feed; b.read = true
        let c = Article(title: "c", identifier: "c", url: "https://x/c")
        c.createdAt = Date(timeIntervalSince1970: 3); c.feed = feed; c.read = true
        let d = Article(title: "d", identifier: "d", url: "https://x/d")
        d.createdAt = Date(timeIntervalSince1970: 4); d.feed = feed
        ctx.insert(a); ctx.insert(b); ctx.insert(c); ctx.insert(d)

        let byTag = TagFilter.apply(to: [a, b, c, d], disabledTagNames: [], includeUntagged: true)
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: [])
        let results = StarredFilter.apply(to: byFeed, starredOnly: false)

        #expect(results.map(\.identifier) == ["a", "b", "c", "d"])
    }
}
