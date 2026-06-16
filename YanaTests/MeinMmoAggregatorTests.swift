import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("MeinMmoAggregator")
struct MeinMmoAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry() -> FeedEntry {
        FeedEntry(title: "Mein-MMO story", link: "https://mein-mmo.de/post-1/", content: "<p>s</p>",
                  summary: "<p>s</p>", entryDescription: nil, published: .now, author: "",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubMmo: MeinMmoAggregator, @unchecked Sendable {
        let first: String; let extraPages: [String: String]
        init(first: String, extraPages: [String: String], options: MeinMmoOptions, store: ImageStore) {
            self.first = first; self.extraPages = extraPages
            super.init(config: FeedConfig(type: .meinMmo, identifier: "https://mein-mmo.de/feed/",
                                          dailyLimit: 20, options: .meinMmo(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { [] }   // not used; aggregate() drives enrich directly
        override func fetchArticleHTML(_ url: String) async throws -> String { first }
        override func fetchAdditionalPage(_ url: String) async throws -> String { extraPages[url] ?? "" }
    }

    /// Drives a single article through enrich() with injected pages.
    private func enrichOne(_ agg: MeinMmoAggregator) async throws -> AggregatedArticle {
        let base = agg.makeArticle(from: entry())
        return try await agg.enrich(base, entry: entry())
    }

    @Test func combinesPagesAndMergesContent() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Page one body</p>\
        <div class="gp-pagination-numbers"><a class="page-numbers" href="https://mein-mmo.de/post-1/2/">2</a></div>\
        </div></body></html>
        """
        let page2 = "<html><body><div class=\"gp-entry-content\"><p>Page two body</p></div></body></html>"
        let agg = StubMmo(first: first, extraPages: ["https://mein-mmo.de/post-1/2/": page2],
                          options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Page one body"))
        #expect(a.content.contains("Page two body"))
    }

    @Test func disablingCombineKeepsFirstPageOnly() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Only page one</p>\
        <div class="gp-pagination-numbers"><a class="page-numbers" href="https://mein-mmo.de/post-1/2/">2</a></div>\
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: ["https://mein-mmo.de/post-1/2/": "<div class=\"gp-entry-content\"><p>Page two</p></div>"],
                          options: { var o = MeinMmoOptions(); o.combinePages = false; return o }(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Only page one"))
        #expect(!a.content.contains("Page two"))
    }

    @Test func convertsDailymotionBlockAndRemovesPaginationMarkers() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Intro</p>\
        <div class="wp-block-mmo-video"><script>var x = { dmVideoId: 'x9yt07o' };</script></div>\
        <p><em>Weiter geht es auf Seite 2.</em></p>\
        <div class="wp-block-mmo-recirculation-box">related junk</div>\
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("dailymotion-embed-container"))
        #expect(a.content.contains("geo.dailymotion.com/player.html?video=x9yt07o"))
        #expect(!a.content.contains("Weiter geht es auf Seite"))
        #expect(!a.content.contains("related junk"))
    }

    @Test func convertsYouTubeFigureEmbed() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Intro</p>\
        <figure class="wp-block-embed-youtube"><a href="https://www.youtube.com/watch?v=abc12345678">link</a></figure>\
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("youtube-nocookie.com/embed/abc12345678"))
    }

    @Test func identifierChoicesHasSingleFeed() {
        #expect(MeinMmoAggregator.identifierChoices.count == 1)
    }
}
