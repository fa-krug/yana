import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Timeline pinning")
struct TimelinePinningTests {
    /// `order` drives `createdAt` (the sort key under test). `date` is deliberately set to an
    /// unrelated, reversed value so these tests prove reinsertion is keyed on `createdAt` (server
    /// insertion order), never `date` (the feed's own, possibly-backfilled publish timestamp) --
    /// closing the exact bug where a pinned article settled at the wrong position because a stale
    /// read article's backfilled `date` happened to sort between it and its true neighbor.
    private func article(_ id: String, order: TimeInterval, read: Bool = false) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.createdAt = Date(timeIntervalSince1970: order)
        a.date = Date(timeIntervalSince1970: 1000 - order)
        a.setRead(read)
        return a
    }

    /// Canonical (readRank, createdAt) order for a/b/c/d: read block first (oldest->newest), then
    /// unread block (oldest->newest). Used as the "already sorted" input every test below starts
    /// from -- matching `Article.readRank`'s `read ? 0 : 1` and the sort descriptors in
    /// `ArticleStore`.
    private func canonical() -> [Article] {
        [
            article("b", order: 2, read: true),    // read
            article("a", order: 1),                // unread
            article("c", order: 3),                // unread
            article("d", order: 4),                // unread
        ]
    }

    @Test func noPinReturnsInputUnchanged() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: nil)
        #expect(result.map(\.identifier) == ["b", "a", "c", "d"])
    }

    @Test func unknownPinnedIdentifierReturnsInputUnchanged() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "missing")
        #expect(result.map(\.identifier) == ["b", "a", "c", "d"])
    }

    @Test func pinningAStillUnreadArticleIsANoOp() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "a")
        #expect(result.map(\.identifier) == ["b", "a", "c", "d"])
    }

    /// The core fix: "b" is read (order 2) but pinned, so it's pulled out of the read block and
    /// reinserted into the unread block at the position its `createdAt` would sort to -- between
    /// "a" (order 1) and "c" (order 3) -- instead of staying at the front of the read block.
    @Test func pinnedReadArticleIsReinsertedAtItsCreatedAtSortedUnreadPosition() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "b")
        #expect(result.map(\.identifier) == ["a", "b", "c", "d"])
    }

    /// A pinned article older (by `createdAt`) than every unread row sorts to the very front of the
    /// unread block, i.e. immediately after the (now empty-of-it) read block.
    @Test func pinnedReadArticleOlderThanAllUnreadSortsFirst() {
        let input = [
            article("z", order: 1, read: true),
            article("x", order: 5),
            article("y", order: 10),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["z", "x", "y"])
    }

    /// A pinned article newer (by `createdAt`) than every unread row sorts to the very back of the
    /// unread block.
    @Test func pinnedReadArticleNewerThanAllUnreadSortsLastInUnreadBlock() {
        let input = [
            article("z", order: 99, read: true),
            article("x", order: 1),
            article("y", order: 2),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["x", "y", "z"])
    }

    /// No unread rows at all: the pinned article becomes the sole occupant of the (now nonempty)
    /// unread block, which sorts immediately after every remaining read row (there's nothing else
    /// in the unread block to compare it against).
    @Test func pinnedReadArticleWithNoUnreadRowsSortsFirst() {
        let input = [
            article("other", order: 1, read: true),
            article("z", order: 2, read: true),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["other", "z"])
    }

    /// Regression guard for the exact bug the final review caught: with MULTIPLE read articles in
    /// the read block, pinning one of them must slot it into the unread block at its
    /// `createdAt`-sorted position, not dump it back at index 0 of the whole array. "p" (order 1)
    /// and "q" (order 3) stay read and untouched; "r" (order 2, pinned) moves out of the read block
    /// and in ahead of "s" (the sole unread row, order 10) since 2 < 10.
    @Test func pinnedReadArticleAmongMultipleReadArticlesInsertsIntoUnreadBlockNotAtFront() {
        let input = [
            article("p", order: 1, read: true),
            article("r", order: 2, read: true),
            article("q", order: 3, read: true),
            article("s", order: 10),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "r")
        #expect(result.map(\.identifier) == ["p", "q", "r", "s"])
    }

    /// `identifier` is only a per-feed dedup key -- two different feeds can share the same source
    /// URL. Without `pinningServerID`, a plain identifier match pins whichever duplicate comes first,
    /// which can be the wrong feed's (still-unread) article and silently reshuffle it as if it were
    /// the one just read. Supplying `pinningServerID` disambiguates to the actual displayed article.
    @Test func pinningServerIDDisambiguatesArticlesThatShareAnIdentifierAcrossFeeds() {
        let otherFeedsCopy = article("dup", order: 1)                    // unread, serverID unset
        let thisFeedsCopy = article("dup", order: 2, read: true)
        thisFeedsCopy.serverID = 99
        // Canonical (readRank, createdAt) order: the read row first, then the unread block ascending.
        let input = [thisFeedsCopy, otherFeedsCopy, article("z", order: 10)]

        let result = TimelinePinning.apply(to: input, pinning: "dup", pinningServerID: 99)

        // The read, serverID-99 copy is pulled out of the read block and reinserted into the unread
        // block at its createdAt-sorted position; the unrelated unread "dup" from the other feed
        // (no serverID) is left completely alone rather than being mistaken for the pin target.
        #expect(result.map(\.serverID) == [nil, 99, nil])
        #expect(result[0] === otherFeedsCopy)
        #expect(result[1] === thisFeedsCopy)
        #expect(result[2].identifier == "z")
    }
}
