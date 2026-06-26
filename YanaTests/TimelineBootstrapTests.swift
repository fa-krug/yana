import Testing
@testable import Yana

struct TimelineBootstrapTests {
    private struct Item: TimelineFilterable, TimelineIdentifiable {
        let identifier: String
        let filterTagNames: [String]
        let filterFeedName: String?
        init(_ id: String, tags: [String] = ["t"], feed: String? = "f") {
            identifier = id; filterTagNames = tags; filterFeedName = feed
        }
    }

    @Test func positionsOnSavedAnchor() {
        let items = [Item("a"), Item("b"), Item("c")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], anchorIdentifier: "b"
        )
        #expect(r.articles.map(\.identifier) == ["a", "b", "c"])
        #expect(r.anchorIndex == 1)
    }

    @Test func fallsBackToNewestWhenAnchorMissing() {
        let items = [Item("a"), Item("b")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], anchorIdentifier: "ghost"
        )
        #expect(r.anchorIndex == 1)   // newest = last index
    }

    @Test func anchorIndexIsRelativeToFilteredList() {
        // "a" is filtered out by its tag; anchor "c" must reindex to 1, not 2.
        let items = [Item("a", tags: ["hidden"]), Item("b"), Item("c")]
        let r = TimelineBootstrap.resolve(
            summaries: items, disabledTagNames: ["hidden"], includeUntagged: false,
            disabledFeedNames: [], anchorIdentifier: "c"
        )
        #expect(r.articles.map(\.identifier) == ["b", "c"])
        #expect(r.anchorIndex == 1)
    }

    @Test func emptyInputYieldsZeroIndex() {
        let r = TimelineBootstrap.resolve(
            summaries: [Item](), disabledTagNames: [], includeUntagged: true,
            disabledFeedNames: [], anchorIdentifier: "x"
        )
        #expect(r.articles.isEmpty)
        #expect(r.anchorIndex == 0)
    }
}
