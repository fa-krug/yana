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
        #expect(TimelineAnchor.index(for: nil, in: []) == 0)
    }
}
