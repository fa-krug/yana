import Foundation
import Testing
@testable import Yana

struct TimelineBootstrapTests {
    private struct Item: TimelineFilterable, TimelineIdentifiable {
        let identifier: String
        let date: Date
        let createdAt: Date
        let serverID: Int?
        let filterTagNames: Set<String>
        let filterFeedName: String?
        let filterStarred: Bool
        let filterRead: Bool
        init(_ id: String, tags: [String] = ["t"], feed: String? = "f", starred: Bool = false, read: Bool = false) {
            identifier = id; date = Date(timeIntervalSince1970: 0); createdAt = Date(timeIntervalSince1970: 0)
            serverID = nil; filterTagNames = Set(tags); filterFeedName = feed; filterStarred = starred; filterRead = read
        }
    }

    @Test func positionsOnSavedAnchor() {
        let items = [Item("a"), Item("b"), Item("c")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: false, readFilter: .all, anchorIdentifier: "b"
        )
        #expect(r.articles.map(\.identifier) == ["a", "b", "c"])
        #expect(r.anchorIndex == 1)
    }

    @Test func fallsBackToNewestWhenAnchorMissing() {
        let items = [Item("a"), Item("b")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: false, readFilter: .all, anchorIdentifier: "ghost"
        )
        #expect(r.anchorIndex == 1)   // newest = last index
    }

    @Test func anchorIndexIsRelativeToFilteredList() {
        // "a" is filtered out by its tag; anchor "c" must reindex to 1, not 2.
        let items = [Item("a", tags: ["hidden"]), Item("b"), Item("c")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: ["hidden"], includeUntagged: false,
            disabledFeedNames: [], starredOnly: false, readFilter: .all, anchorIdentifier: "c"
        )
        #expect(r.articles.map(\.identifier) == ["b", "c"])
        #expect(r.anchorIndex == 1)
    }

    @Test func emptyInputYieldsZeroIndex() {
        let r = TimelineBootstrap.resolve(
            summaries: [Item](), disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: false, readFilter: .all, anchorIdentifier: "x"
        )
        #expect(r.articles.isEmpty)
        #expect(r.anchorIndex == 0)
    }

    @Test func readFilterNarrowsToUnreadOrRead() {
        let items = [Item("a", read: true), Item("b", read: false), Item("c", read: true)]
        let unread = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: false, readFilter: .unread, anchorIdentifier: "b"
        )
        #expect(unread.articles.map(\.identifier) == ["b"])
        #expect(unread.anchorIndex == 0)

        let read = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: false, readFilter: .read, anchorIdentifier: "c"
        )
        #expect(read.articles.map(\.identifier) == ["a", "c"])
        #expect(read.anchorIndex == 1)
    }

    /// The anchored article is the one the reader is about to open, so a read filter that would
    /// otherwise exclude it must not: resuming has to land on the article the user left off on.
    @Test func anchoredArticleSurvivesTheReadFilter() {
        let items = [Item("a", read: false), Item("b", read: true), Item("c", read: false)]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: false, readFilter: .unread, anchorIdentifier: "b"
        )
        #expect(r.articles.map(\.identifier) == ["a", "b", "c"])
        #expect(r.anchorIndex == 1)
    }

    @Test func starredOnlyFiltersToStarredItems() {
        let items = [Item("a", starred: false), Item("b", starred: true), Item("c", starred: false)]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: true, readFilter: .all, anchorIdentifier: "b"
        )
        #expect(r.articles.map(\.identifier) == ["b"])
        #expect(r.anchorIndex == 0)
    }
}
