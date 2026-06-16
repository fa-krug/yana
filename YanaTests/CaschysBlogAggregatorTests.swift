import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("CaschysBlogAggregator")
struct CaschysBlogAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry(_ title: String) -> FeedEntry {
        FeedEntry(title: title, link: "https://stadt-bremerhaven.de/post-1/", content: "<p>s</p>",
                  summary: "<p>s</p>", entryDescription: nil, published: .now, author: "",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubCaschy: CaschysBlogAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, options: CaschysBlogOptions, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .caschysBlog, identifier: "https://stadt-bremerhaven.de/feed/",
                                          dailyLimit: 20, options: .caschysBlog(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func extractsEntryInnerAndStripsAawpAndDisallowedIframe() async throws {
        let page = """
        <html><body><div class="entry-inner"><p>Body text</p>\
        <div class="aawp">affiliate</div>\
        <iframe src="https://evil.example.com/x"></iframe>\
        <iframe src="https://www.youtube.com/embed/abc12345678"></iframe>\
        </div></body></html>
        """
        let agg = StubCaschy(entries: [entry("Post")], page: page, options: CaschysBlogOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Body text"))
        #expect(!a.content.contains("affiliate"))            // .aawp removed
        #expect(!a.content.contains("evil.example.com"))      // disallowed iframe removed
        #expect(a.content.contains("youtube-nocookie.com/embed/abc12345678"))  // YouTube kept + rewritten
    }

    @Test func skipsAnzeigeAndWeeklyRecap() async throws {
        let agg = StubCaschy(entries: [
            entry("Cooles Gadget (Anzeige)"),
            entry("Immer wieder sonntags KW 24"),
            entry("Echte News"),
        ], page: "<div class=\"entry-inner\"><p>x</p></div>", options: CaschysBlogOptions(), store: tempStore())
        let titles = try await agg.aggregate().map(\.title)
        #expect(titles == ["Echte News"])
    }

    @Test func identifierChoicesHasSingleFeed() {
        #expect(CaschysBlogAggregator.identifierChoices.count == 1)
        #expect(CaschysBlogAggregator.identifierChoices.first?.value == "https://stadt-bremerhaven.de/feed/")
    }
}
