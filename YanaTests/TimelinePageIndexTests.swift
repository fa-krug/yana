import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Timeline page index")
struct TimelinePageIndexTests {
    private func article(_ id: String) -> Article {
        Article(title: id, identifier: id, url: "https://x.com/\(id)")
    }

    @Test func returnsIndexOfMatchingIdentifier() {
        let list = [article("a"), article("b"), article("c")]
        #expect(TimelinePageIndex.index(of: "a", in: list) == 0)
        #expect(TimelinePageIndex.index(of: "c", in: list) == 2)
    }

    @Test func returnsNilWhenAbsentOrNil() {
        let list = [article("a"), article("b")]
        #expect(TimelinePageIndex.index(of: "missing", in: list) == nil)
        #expect(TimelinePageIndex.index(of: nil, in: list) == nil)
        #expect(TimelinePageIndex.index(of: "a", in: []) == nil)
    }

    @Test func anchorStillFallsBackToZero() {
        let list = [article("a"), article("b")]
        #expect(TimelineAnchor.index(for: "b", in: list) == 1)
        #expect(TimelineAnchor.index(for: "missing", in: list) == 0)
        #expect(TimelineAnchor.index(for: nil, in: list) == 0)
    }
}
