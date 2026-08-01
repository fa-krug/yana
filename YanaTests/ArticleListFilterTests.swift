import Testing
import SwiftData
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func listResultsAreSubsetAndJumpResolves() throws {
        let ctx = try makeContext()
        let feedA = Feed(name: "Alpha", aggregatorType: .feedContent, identifier: "a")
        let feedB = Feed(name: "Beta", aggregatorType: .feedContent, identifier: "b")
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
}
