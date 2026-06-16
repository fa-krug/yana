import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("FullWebsiteAggregator")
struct FullWebsiteAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    final class StubWebsite: FullWebsiteAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .fullWebsite, identifier: "u", dailyLimit: 20,
                                          options: .fullWebsite(WebsiteOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func extractsMainContentBySelector() async throws {
        let entry = FeedEntry(title: "T", link: "https://x.com/1", content: "<p>summary</p>",
                              summary: "<p>summary</p>", entryDescription: nil, published: .now, author: "",
                              enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
        let page = "<html><body><article><p>Full article body</p></article><div class=\"ad\">AD</div></body></html>"
        let agg = StubWebsite(entries: [entry], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Full article body"))
        #expect(!a.content.contains("AD"))
        #expect(a.content.contains("article-content"))
    }

    @Test func disabledFullContentKeepsRssSummary() async throws {
        let entry = FeedEntry(title: "T", link: "https://x.com/1", content: "<p>just summary</p>",
                              summary: "<p>just summary</p>", entryDescription: nil, published: .now, author: "",
                              enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
        final class StubAggregator: FullWebsiteAggregator, @unchecked Sendable {
            let e: [FeedEntry]
            init(_ e: [FeedEntry], _ store: ImageStore) {
                self.e = e
                super.init(config: FeedConfig(type: .fullWebsite, identifier: "u", dailyLimit: 20,
                           options: .fullWebsite({ var o = WebsiteOptions(); o.useFullContent = false; return o }()),
                           collectedToday: 0), credentials: .init(), store: store)
            }
            override func fetchEntries() async throws -> [FeedEntry] { e }
            override func fetchArticleHTML(_ url: String) async throws -> String { "<article>SHOULD NOT FETCH</article>" }
        }
        let agg = StubAggregator([entry], tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("just summary"))
        #expect(!a.content.contains("SHOULD NOT FETCH"))
    }

    @Test func fetchFailureFallbackStillLocalizesImages() async throws {
        final class FailingFetch: FullWebsiteAggregator, @unchecked Sendable {
            let e: [FeedEntry]
            init(_ e: [FeedEntry], _ store: ImageStore) {
                self.e = e
                super.init(config: FeedConfig(type: .fullWebsite, identifier: "u", dailyLimit: 20,
                           options: .fullWebsite(WebsiteOptions()), collectedToday: 0),
                           credentials: .init(), store: store)
            }
            override func fetchEntries() async throws -> [FeedEntry] { e }
            override func fetchArticleHTML(_ url: String) async throws -> String {
                throw AggregatorError.contentFetch("boom")   // non-skip error → fallback path
            }
        }
        let entry = FeedEntry(title: "T", link: "https://x.com/1",
                              content: "<p>sum</p><img src=\"https://x.com/p.png\">",
                              summary: "<p>sum</p><img src=\"https://x.com/p.png\">", entryDescription: nil,
                              published: .now, author: "", enclosures: [], itunesDuration: nil,
                              itunesImage: nil, mediaThumbnails: [])
        let agg = FailingFetch([entry], tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("sum"))                           // RSS content preserved
        #expect(!a.content.contains("https://x.com/p.png"))           // NO remote image URL leaks
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))    // image localized in fallback
    }
}
