import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleListFiltering")
struct ArticleListFilteringTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Article.self, Feed.self, Tag.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try makeContainer())
    }

    /// Tag membership is a live join from `feed?.tagIDs` against synced `Tag.serverID`s (not the
    /// old per-article `Article.tags` snapshot), so an untagged article just gets its own
    /// feed with no tag ids -- no `Tag` row needed for that case.
    private func article(title: String, feed: Feed, in context: ModelContext) -> Article {
        let a = Article(title: title, identifier: UUID().uuidString, url: "u")
        a.feed = feed
        context.insert(a)
        return a
    }

    @Test func searchThenTagFilterCompose() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let techFeed = Feed(name: "Tech Feed", identifier: "tech")
        techFeed.tagIDs = [1]
        let foodFeed = Feed(name: "Food Feed", identifier: "food")
        foodFeed.tagIDs = [2]
        let techTag = Tag(name: "Tech"); techTag.serverID = 1
        let foodTag = Tag(name: "Food"); foodTag.serverID = 2
        context.insert(techFeed); context.insert(foodFeed)
        context.insert(techTag); context.insert(foodTag)

        _ = article(title: "Swift news", feed: techFeed, in: context)
        _ = article(title: "Swift cooking", feed: foodFeed, in: context)
        _ = article(title: "Rust news", feed: techFeed, in: context)
        try context.save()

        let searched = await ArticleSearch.searchSummaries(query: "swift", container: container) // -> 2 articles
        let filtered = TagFilter.apply(to: searched, disabledTagNames: ["Food"], includeUntagged: true)
        #expect(filtered.count == 1)
        #expect(filtered.first?.title == "Swift news")
    }

    @Test func untaggedExcludedWhenFlagOff() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let feed = Feed(name: "Feed", identifier: "f")
        context.insert(feed)
        _ = article(title: "Swift", feed: feed, in: context)
        try context.save()
        let searched = await ArticleSearch.searchSummaries(query: "swift", container: container)
        #expect(TagFilter.apply(to: searched, disabledTagNames: [], includeUntagged: false).isEmpty)
    }
}
