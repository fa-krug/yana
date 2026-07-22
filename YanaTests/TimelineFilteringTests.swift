import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Timeline filtering + anchor")
struct TimelineFilteringTests {
    private func article(_ id: String, tags: [Yana.Tag]) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.tags = tags
        return a
    }

    private func article(_ id: String, createdAt: Date) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.createdAt = createdAt
        return a
    }

    @Test func untaggedRespectsToggle() {
        let a = article("a", tags: [])
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: true).count == 1)
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: false).isEmpty)
    }

    @Test func showsArticleWithAnyActiveTag() {
        let tech = Yana.Tag(name: "Tech")
        let fun = Yana.Tag(name: "Fun")
        let a = article("a", tags: [tech, fun])
        // Tech disabled but Fun active -> still shown.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech"], includeUntagged: true).count == 1)
        // Both disabled -> hidden.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech", "Fun"], includeUntagged: true).isEmpty)
    }

    @Test func anchorResolvesToIndexOrNewest() {
        let a = article("a", tags: [])
        let b = article("b", tags: [])
        let list = [a, b]
        #expect(TimelineAnchor.index(for: "a", in: list) == 0)
        #expect(TimelineAnchor.index(for: "b", in: list) == 1)
        // No / missing memory falls back to the newest article (last in the ascending timeline),
        // not the oldest, so a first launch opens on fresh content.
        #expect(TimelineAnchor.index(for: "missing", in: list) == 1)
        #expect(TimelineAnchor.index(for: nil, in: list) == 1)
        #expect(TimelineAnchor.index(for: nil, in: [] as [Article]) == 0)
    }

    @Test func closestByTimestampPicksNearestArticle() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = article("a", createdAt: base)                       // t+0
        let b = article("b", createdAt: base.addingTimeInterval(100)) // t+100
        let c = article("c", createdAt: base.addingTimeInterval(300)) // t+300
        let list = [a, b, c]

        // Exact match.
        #expect(TimelineClosest.index(closestTo: base, in: list) == 0)
        // Between b and c, closer to b.
        #expect(TimelineClosest.index(closestTo: base.addingTimeInterval(160), in: list) == 1)
        // Beyond the newest -> clamps to the last.
        #expect(TimelineClosest.index(closestTo: base.addingTimeInterval(10_000), in: list) == 2)
        // Before the oldest -> clamps to the first.
        #expect(TimelineClosest.index(closestTo: base.addingTimeInterval(-10_000), in: list) == 0)
        // Empty list.
        #expect(TimelineClosest.index(closestTo: base, in: [] as [Article]) == nil)
    }
}
