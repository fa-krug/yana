import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("TheVergeAggregator")
struct TheVergeAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry() -> FeedEntry {
        FeedEntry(title: "Verge story", link: "https://www.theverge.com/a-1", content: "<p>s</p>",
                  summary: "<p>s</p>", entryDescription: nil, published: .now, author: "",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubVerge: TheVergeAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .theVerge, identifier: "https://www.theverge.com/rss/index.xml",
                                          dailyLimit: 20, options: .theVerge(TheVergeOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func extractsOnlyFirstArticleBodyBlock() async throws {
        // The Verge embeds related/"stream" article bodies with the same class; keep only the first.
        let page = """
        <html><body>
        <div class="duet--article--article-body-component"><p>Main article body</p></div>
        <div class="duet--article--article-body-component"><p>Related stream article</p></div>
        </body></html>
        """
        let agg = StubVerge(entries: [entry()], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Main article body"))
        #expect(!a.content.contains("Related stream article"))
    }

    @Test func extractsFromDuetBodyNotSurroundingArticle() async throws {
        // The page wraps everything in <article> (which the generic default selectors would grab);
        // The Verge must extract from its `.duet--article--article-body-component` block instead, so
        // surrounding chrome/related content outside that block is dropped.
        let page = """
        <html><body><article>
        <div class="site-nav">NAVNOISE</div>
        <div class="duet--article--article-body-component"><p>Real body text</p></div>
        <div class="duet--recirculation--related">RELATEDNOISE</div>
        </article></body></html>
        """
        let agg = StubVerge(entries: [entry()], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Real body text"))
        #expect(!a.content.contains("NAVNOISE"))
        #expect(!a.content.contains("RELATEDNOISE"))
    }

    @Test func removesAdAndNewsletterNoise() async throws {
        let page = """
        <div class="duet--article--article-body-component"><p>Keep this</p>\
        <div class="duet--ad-slot">ADCONTENT</div>\
        <div class="newsletter-signup">NEWSLETTERCONTENT</div></div>
        """
        let agg = StubVerge(entries: [entry()], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Keep this"))
        #expect(!a.content.contains("ADCONTENT"))
        #expect(!a.content.contains("NEWSLETTERCONTENT"))
    }

    @Test func identifierChoicesHasMainFeed() {
        #expect(TheVergeAggregator.identifierChoices.count == 1)
        #expect(TheVergeAggregator.identifierChoices.first?.value == "https://www.theverge.com/rss/index.xml")
    }
}
