import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Timeline filtering + anchor")
struct TimelineFilteringTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Article.self, Feed.self, Yana.Tag.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// `Article.filterTagNames` resolves live: `feed?.tagIDs` joined against every synced
    /// `Tag`'s `serverID`. An `Article` outside a `ModelContext` (no `feed`, or no context to
    /// fetch `Tag` rows from) always reads as untagged -- so the article/feed/tags below must
    /// all be inserted for the join to resolve anything.
    private func article(_ id: String, tagIDs: [Int], in context: ModelContext) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        let feed = Feed(name: "Feed-\(id)", identifier: "feed-\(id)")
        feed.tagIDs = tagIDs
        a.feed = feed
        context.insert(feed)
        context.insert(a)
        return a
    }

    @Test func untaggedRespectsToggle() throws {
        let context = try makeContext()
        let a = article("a", tagIDs: [], in: context)
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: true).count == 1)
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: false).isEmpty)
    }

    @Test func showsArticleWithAnyActiveTag() throws {
        let context = try makeContext()
        let tech = Yana.Tag(name: "Tech")
        tech.serverID = 1
        let fun = Yana.Tag(name: "Fun")
        fun.serverID = 2
        context.insert(tech)
        context.insert(fun)
        let a = article("a", tagIDs: [1, 2], in: context)
        // Tech disabled but Fun active -> still shown.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech"], includeUntagged: true).count == 1)
        // Both disabled -> hidden.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech", "Fun"], includeUntagged: true).isEmpty)
    }

    @Test func starredOnlyFiltersOutUnstarred() throws {
        let context = try makeContext()
        let starred = article("a", tagIDs: [], in: context)
        starred.starred = true
        let unstarred = article("b", tagIDs: [], in: context)
        #expect(StarredFilter.apply(to: [starred, unstarred], starredOnly: false).count == 2)
        #expect(StarredFilter.apply(to: [starred, unstarred], starredOnly: true).map(\.identifier) == ["a"])
    }

    @Test func filterReadMirrorsReadOnArticleAndSummary() throws {
        let context = try makeContext()
        let a = article("a", tagIDs: [], in: context)
        a.read = true
        #expect(a.filterRead == true)

        let summary = ArticleSummary(a)
        #expect(summary.filterRead == true)
        #expect(summary.filterRead == summary.isRead)
    }

    @Test func anchorResolvesToIndexOrNewest() throws {
        let context = try makeContext()
        let a = article("a", tagIDs: [], in: context)
        let b = article("b", tagIDs: [], in: context)
        let list = [a, b]
        #expect(TimelineAnchor.index(for: "a", in: list) == 0)
        #expect(TimelineAnchor.index(for: "b", in: list) == 1)
        // No / missing memory falls back to the newest article (last in the ascending timeline),
        // not the oldest, so a first launch opens on fresh content.
        #expect(TimelineAnchor.index(for: "missing", in: list) == 1)
        #expect(TimelineAnchor.index(for: nil, in: list) == 1)
        #expect(TimelineAnchor.index(for: nil, in: [] as [Article]) == 0)
    }
}
