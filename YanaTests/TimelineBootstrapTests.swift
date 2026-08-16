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
            disabledFeedNames: [], starredOnly: false, anchorIdentifier: "b"
        )
        #expect(r.articles.map(\.identifier) == ["a", "b", "c"])
        #expect(r.anchorIndex == 1)
    }

    @Test func fallsBackToNewestWhenAnchorMissing() {
        let items = [Item("a"), Item("b")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: false, anchorIdentifier: "ghost"
        )
        #expect(r.anchorIndex == 1)   // newest = last index
    }

    @Test func anchorIndexIsRelativeToFilteredList() {
        // "a" is filtered out by its tag; anchor "c" must reindex to 1, not 2.
        let items = [Item("a", tags: ["hidden"]), Item("b"), Item("c")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: ["hidden"], includeUntagged: false,
            disabledFeedNames: [], starredOnly: false, anchorIdentifier: "c"
        )
        #expect(r.articles.map(\.identifier) == ["b", "c"])
        #expect(r.anchorIndex == 1)
    }

    @Test func emptyInputYieldsZeroIndex() {
        let r = TimelineBootstrap.resolve(
            summaries: [Item](), disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: false, anchorIdentifier: "x"
        )
        #expect(r.articles.isEmpty)
        #expect(r.anchorIndex == 0)
    }

    @Test func starredOnlyFiltersToStarredItems() {
        let items = [Item("a", starred: false), Item("b", starred: true), Item("c", starred: false)]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], starredOnly: true, anchorIdentifier: "b"
        )
        #expect(r.articles.map(\.identifier) == ["b"])
        #expect(r.anchorIndex == 0)
    }
}
