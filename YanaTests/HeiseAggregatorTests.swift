import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("HeiseAggregator")
struct HeiseAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry(_ title: String, link: String = "https://heise.de/-1") -> FeedEntry {
        FeedEntry(title: title, link: link, content: "<p>summary</p>", summary: "<p>summary</p>",
                  entryDescription: nil, published: .now, author: "", enclosures: [],
                  itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    /// Subclass injecting feed entries, the article page, and forum HTML.
    final class StubHeise: HeiseAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String; let forum: String
        var requestedArticleURL: String?
        init(entries: [FeedEntry], page: String, forum: String, options: HeiseOptions, store: ImageStore) {
            self.entries = entries; self.page = page; self.forum = forum
            super.init(config: FeedConfig(type: .heise, identifier: "https://www.heise.de/rss/heise.rdf",
                                          dailyLimit: 20, options: .heise(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { requestedArticleURL = url; return page }
        override func fetchCommentsHTML(_ url: String) async throws -> String { forum }
    }

    @Test func extractsStoryContentAndAppendsAllPagesParam() async throws {
        let page = """
        <html><body><article class="StoryContent"><p>Real body</p>\
        <section>nav junk</section><p></p></article></body></html>
        """
        let agg = StubHeise(entries: [entry("Normal article")], page: page, forum: "",
                            options: { var o = HeiseOptions(); o.includeComments = false; return o }(),
                            store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Real body"))
        #expect(!a.content.contains("nav junk"))        // <section> removed
        #expect(agg.requestedArticleURL?.contains("seite=all") == true)
    }

    @Test func skipsTitlesInSkipList() async throws {
        let agg = StubHeise(entries: [entry("heise+ exclusive"), entry("Keeper")],
                            page: "<article class=\"StoryContent\"><p>x</p></article>", forum: "",
                            options: { var o = HeiseOptions(); o.includeComments = false; return o }(),
                            store: tempStore())
        let titles = try await agg.aggregate().map(\.title)
        #expect(titles == ["Keeper"])
    }

    @Test func skipsEventSourcingInContent() async throws {
        let page = "<article class=\"StoryContent\"><p>About Event Sourcing patterns</p></article>"
        let agg = StubHeise(entries: [entry("Patterns")], page: page, forum: "",
                            options: { var o = HeiseOptions(); o.includeComments = false; return o }(),
                            store: tempStore())
        #expect(try await agg.aggregate().isEmpty)
    }

    @Test func extractsForumCommentsAsBlockquotesCappedAtMax() async throws {
        let page = """
        <html><head><script type="application/ld+json">\
        {"discussionUrl": "https://www.heise.de/forum/123/"}</script></head>\
        <body><article class="StoryContent"><p>Body</p></article></body></html>
        """
        let forum = """
        <ul><li class="posting_element"><span class="pseudonym">Alice</span>\
        <a class="posting_subject" href="/forum/p1">First take</a></li>\
        <li class="posting_element"><span class="pseudonym">Bob</span>\
        <a class="posting_subject" href="/forum/p2">Second take</a></li>\
        <li class="posting_element"><span class="pseudonym">Carol</span>\
        <a class="posting_subject" href="/forum/p3">Third take</a></li></ul>
        """
        let agg = StubHeise(entries: [entry("With comments")], page: page, forum: forum,
                            options: { var o = HeiseOptions(); o.includeComments = true; o.maxComments = 2; return o }(),
                            store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("article-comments"))
        #expect(a.content.contains("First take"))
        #expect(a.content.contains("Second take"))
        #expect(!a.content.contains("Third take"))      // capped at maxComments = 2
        #expect(a.content.contains("<blockquote"))
    }

    @Test func skipsTitleCaseInsensitive() async throws {
        // "die Bilder der Woche" is in the skip list but real titles start with uppercase "Die".
        let agg = StubHeise(
            entries: [entry("Die Bilder der Woche 1234"), entry("Normal Article")],
            page: "<article class=\"StoryContent\"><p>x</p></article>", forum: "",
            options: { var o = HeiseOptions(); o.includeComments = false; return o }(),
            store: tempStore())
        let titles = try await agg.aggregate().map(\.title)
        #expect(titles == ["Normal Article"])
    }

    @Test func includesNormalTitleNotInSkipList() async throws {
        let agg = StubHeise(
            entries: [entry("Apple kündigt neues iPad an")],
            page: "<article class=\"StoryContent\"><p>Details</p></article>", forum: "",
            options: { var o = HeiseOptions(); o.includeComments = false; return o }(),
            store: tempStore())
        let titles = try await agg.aggregate().map(\.title)
        #expect(titles == ["Apple kündigt neues iPad an"])
    }

    @Test func identifierChoicesHasFourHeiseFeeds() {
        #expect(HeiseAggregator.identifierChoices.count == 4)
        #expect(HeiseAggregator.identifierChoices.first?.value == "https://www.heise.de/rss/heise.rdf")
    }
}
