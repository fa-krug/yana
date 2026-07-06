import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("ArsTechnicaAggregator")
struct ArsTechnicaAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry() -> FeedEntry {
        FeedEntry(title: "Ars story", link: "https://arstechnica.com/a/2026/07/x/", content: "<p>s</p>",
                  summary: "<p>s</p>", entryDescription: nil, published: .now, author: "",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubArs: ArsTechnicaAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .arsTechnica, identifier: "https://arstechnica.com/feed/",
                                          dailyLimit: 20, options: .arsTechnica(ArsTechnicaOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func mergesAllPostContentBlocksFromOnePage() async throws {
        // Multi-"page" Ars articles serve every page in one fetch as sibling .post-content blocks.
        let page = """
        <html><body>
        <div class="post-content post-content-double"><p>Page one prose</p></div>
        <a data-page="2" class="record-pageview"></a>
        <div class="post-content post-content-double"><p>Page two prose</p></div>
        </body></html>
        """
        let agg = StubArs(entries: [entry()], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Page one prose"))
        #expect(a.content.contains("Page two prose"))   // not truncated to the first block
    }

    @Test func removesAdWrappers() async throws {
        let page = """
        <div class="post-content post-content-double"><p>Keep this</p>\
        <div class="ad-wrapper is-rail">ADCONTENT</div></div>
        """
        let agg = StubArs(entries: [entry()], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Keep this"))
        #expect(!a.content.contains("ADCONTENT"))
    }

    @Test func fallsBackToRSSContentWhenNoPostContentBlocks() async throws {
        // A page with zero .post-content blocks → mergedContentHTML returns nil → RSS-content fallback.
        let rssEntry = FeedEntry(title: "Ars story", link: "https://arstechnica.com/a/2026/07/x/",
                                 content: "<p>RSSFALLBACKBODY</p>", summary: "<p>RSSFALLBACKBODY</p>",
                                 entryDescription: nil, published: .now, author: "",
                                 enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
        let page = "<html><body><article><p>UNSCRAPEDPAGEBODY</p></article></body></html>"
        let agg = StubArs(entries: [rssEntry], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("RSSFALLBACKBODY"))     // RSS feed content preserved on fallback
        #expect(!a.content.contains("UNSCRAPEDPAGEBODY"))  // page had no .post-content, not scraped
    }

    @Test func identifierChoicesHasFourSections() {
        #expect(ArsTechnicaAggregator.identifierChoices.count == 4)
        #expect(ArsTechnicaAggregator.identifierChoices.map(\.value) == [
            "https://arstechnica.com/feed/",
            "https://arstechnica.com/gadgets/feed/",
            "https://arstechnica.com/science/feed/",
            "https://arstechnica.com/gaming/feed/",
        ])
    }
}
