import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Timeline display order")
struct TimelineDisplayOrderTests {
    private func article(_ id: String) -> Article {
        Article(title: id, identifier: id, url: "https://x.com/\(id)")
    }

    @Test func firstMergeAdoptsCanonicalOrderWhenPreviousIsEmpty() {
        let canonical = [article("a"), article("b")]
        let merged = TimelineDisplayOrder.merge(previous: [], canonical: canonical)
        #expect(merged.map(\.identifier) == ["a", "b"])
    }

    /// The bug this guards against: a read-state flip re-sorts `canonical` (unread article "b"
    /// moves ahead of newly-read "a"), but the pager must keep showing "a" then "b" so its
    /// swipe-forward neighbor doesn't change out from under the user mid-session.
    @Test func preservesExistingOrderWhenCanonicalReorders() {
        let previous = [article("a"), article("b"), article("c")]
        let reordered = [article("b"), article("a"), article("c")] // simulates a's read-flip re-sort
        let merged = TimelineDisplayOrder.merge(previous: previous, canonical: reordered)
        #expect(merged.map(\.identifier) == ["a", "b", "c"])
    }

    @Test func appendsGenuinelyNewItemsAtTheEndInCanonicalOrder() {
        let previous = [article("a"), article("b")]
        let canonical = [article("new1"), article("a"), article("b"), article("new2")]
        let merged = TimelineDisplayOrder.merge(previous: previous, canonical: canonical)
        #expect(merged.map(\.identifier) == ["a", "b", "new1", "new2"])
    }

    @Test func dropsItemsNoLongerInCanonical() {
        let previous = [article("a"), article("b"), article("c")]
        let canonical = [article("a"), article("c")] // "b" removed/filtered out
        let merged = TimelineDisplayOrder.merge(previous: previous, canonical: canonical)
        #expect(merged.map(\.identifier) == ["a", "c"])
    }

    @Test func refreshesFieldValuesFromCanonicalWhileKeepingPosition() {
        let stale = article("a")
        stale.title = "Old Title"
        let fresh = article("a")
        fresh.title = "New Title"
        let merged = TimelineDisplayOrder.merge(previous: [stale], canonical: [fresh])
        #expect(merged.map(\.title) == ["New Title"])
    }
}
