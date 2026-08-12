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

    /// Canonical (readRank, date) order for a/b/c/d: unread block first (oldest->newest), then
    /// read block (oldest->newest). Used as the "already sorted" input every test below starts from.
    private func canonical() -> [Article] {
        [
            article("a", date: 1),               // unread
            article("c", date: 3),                // unread
            article("d", date: 4),                // unread
            article("b", date: 2, read: true),     // read
        ]
    }

    @Test func noPinReturnsInputUnchanged() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: nil)
        #expect(result.map(\.identifier) == ["a", "c", "d", "b"])
    }

    @Test func unknownPinnedIdentifierReturnsInputUnchanged() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "missing")
        #expect(result.map(\.identifier) == ["a", "c", "d", "b"])
    }

    @Test func pinningAStillUnreadArticleIsANoOp() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "a")
        #expect(result.map(\.identifier) == ["a", "c", "d", "b"])
    }

    /// The core fix: "b" is read (date 2) but pinned, so it's reinserted into the unread block at
    /// the position its date would sort to -- between "a" (date 1) and "c" (date 3) -- instead of
    /// staying at the back of the read block.
    @Test func pinnedReadArticleIsReinsertedAtItsDateSortedUnreadPosition() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "b")
        #expect(result.map(\.identifier) == ["a", "b", "c", "d"])
    }

    /// A pinned article older than every unread row sorts to the very front of the unread block.
    @Test func pinnedReadArticleOlderThanAllUnreadSortsFirst() {
        let input = [
            article("x", date: 5),
            article("y", date: 10),
            article("z", date: 1, read: true),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["z", "x", "y"])
    }

    /// A pinned article newer than every unread row sorts to the very back of the unread block,
    /// i.e. immediately ahead of the (now empty-of-it) read block.
    @Test func pinnedReadArticleNewerThanAllUnreadSortsLastInUnreadBlock() {
        let input = [
            article("x", date: 1),
            article("y", date: 2),
            article("z", date: 99, read: true),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["x", "y", "z"])
    }

    /// No unread rows at all: the pinned article becomes the sole occupant of the (now nonempty)
    /// unread block, ahead of every other read row.
    @Test func pinnedReadArticleWithNoUnreadRowsSortsFirst() {
        let input = [
            article("other", date: 1, read: true),
            article("z", date: 2, read: true),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["z", "other"])
    }
}
