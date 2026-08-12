import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Timeline pinning")
struct TimelinePinningTests {
    private func article(_ id: String, date: TimeInterval, read: Bool = false) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.date = Date(timeIntervalSince1970: date)
        a.setRead(read)
        return a
    }

    /// Canonical (readRank, date) order for a/b/c/d: read block first (oldest->newest), then
    /// unread block (oldest->newest). Used as the "already sorted" input every test below starts
    /// from -- matching `Article.readRank`'s `read ? 0 : 1` and the sort descriptors in
    /// `ArticleStore`.
    private func canonical() -> [Article] {
        [
            article("b", date: 2, read: true),    // read
            article("a", date: 1),                // unread
            article("c", date: 3),                // unread
            article("d", date: 4),                // unread
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

    /// The core fix: "b" is read (date 2) but pinned, so it's pulled out of the read block and
    /// reinserted into the unread block at the position its date would sort to -- between "a"
    /// (date 1) and "c" (date 3) -- instead of staying at the front of the read block.
    @Test func pinnedReadArticleIsReinsertedAtItsDateSortedUnreadPosition() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "b")
        #expect(result.map(\.identifier) == ["a", "b", "c", "d"])
    }

    /// A pinned article older than every unread row sorts to the very front of the unread block,
    /// i.e. immediately after the (now empty-of-it) read block.
    @Test func pinnedReadArticleOlderThanAllUnreadSortsFirst() {
        let input = [
            article("z", date: 1, read: true),
            article("x", date: 5),
            article("y", date: 10),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["z", "x", "y"])
    }

    /// A pinned article newer than every unread row sorts to the very back of the unread block.
    @Test func pinnedReadArticleNewerThanAllUnreadSortsLastInUnreadBlock() {
        let input = [
            article("z", date: 99, read: true),
            article("x", date: 1),
            article("y", date: 2),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["x", "y", "z"])
    }

    /// No unread rows at all: the pinned article becomes the sole occupant of the (now nonempty)
    /// unread block, which sorts immediately after every remaining read row (there's nothing else
    /// in the unread block to compare it against).
    @Test func pinnedReadArticleWithNoUnreadRowsSortsFirst() {
        let input = [
            article("other", date: 1, read: true),
            article("z", date: 2, read: true),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["other", "z"])
    }

    /// Regression guard for the exact bug the final review caught: with MULTIPLE read articles in
    /// the read block, pinning one of them must slot it into the unread block at its date-sorted
    /// position, not dump it back at index 0 of the whole array. "p" (date 1) and "q" (date 3) stay
    /// read and untouched; "r" (date 2, pinned) moves out of the read block and in ahead of "s" (the
    /// sole unread row, date 10) since 2 < 10.
    @Test func pinnedReadArticleAmongMultipleReadArticlesInsertsIntoUnreadBlockNotAtFront() {
        let input = [
            article("p", date: 1, read: true),
            article("r", date: 2, read: true),
            article("q", date: 3, read: true),
            article("s", date: 10),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "r")
        #expect(result.map(\.identifier) == ["p", "q", "r", "s"])
    }
}
