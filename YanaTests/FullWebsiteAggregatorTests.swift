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

    @Test func refetchReExtractsContentFromArticleURL() async throws {
        let page = "<html><body><article><p>Refetched body</p></article><div class=\"ad\">AD</div></body></html>"
        let agg = StubWebsite(entries: [], page: page, store: tempStore())
        let seed = AggregatedArticle(title: "T", identifier: "https://x.com/1", url: "https://x.com/1",
                                     rawContent: "", content: "stale", date: .now, author: "", iconURL: nil)
        let refreshed = try #require(try await agg.refetch(seed))
        #expect(refreshed.content.contains("Refetched body"))
        #expect(!refreshed.content.contains("AD"))
        #expect(refreshed.identifier == "https://x.com/1")   // identity preserved for upsert
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

    /// A cancelled run (e.g. an expired background-refresh window) surfaces as `URLError.cancelled`
    /// during the page fetch. Unlike a genuine fetch failure, it must NOT fall back to feed content
    /// — that produced the "background shows just the feed content" bug. The run stops cleanly,
    /// dropping the unscraped entry rather than persisting a feed-only article.
    @Test func cancellationDoesNotPersistFeedContentFallback() async throws {
        final class CancelledFetch: FullWebsiteAggregator, @unchecked Sendable {
            let e: [FeedEntry]
            init(_ e: [FeedEntry], _ store: ImageStore) {
                self.e = e
                super.init(config: FeedConfig(type: .fullWebsite, identifier: "u", dailyLimit: 20,
                           options: .fullWebsite(WebsiteOptions()), collectedToday: 0),
                           credentials: .init(), store: store)
            }
            override func fetchEntries() async throws -> [FeedEntry] { e }
            override func fetchArticleHTML(_ url: String) async throws -> String {
                throw URLError(.cancelled)                            // task cancellation, not a real failure
            }
        }
        let entry = FeedEntry(title: "T", link: "https://x.com/1", content: "<p>feed only</p>",
                              summary: "<p>feed only</p>", entryDescription: nil, published: .now, author: "",
                              enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
        let agg = CancelledFetch([entry], tempStore())
        let articles = try await agg.aggregate()
        #expect(articles.isEmpty)                                     // no feed-content fallback persisted
    }

    /// On cancellation mid-run, entries already fully scraped are kept; the loop stops at the
    /// cancelled entry rather than degrading it (or the rest) to feed content.
    @Test func cancellationKeepsAlreadyScrapedEntries() async throws {
        final class HalfCancelledFetch: FullWebsiteAggregator, @unchecked Sendable {
            let e: [FeedEntry]
            init(_ e: [FeedEntry], _ store: ImageStore) {
                self.e = e
                super.init(config: FeedConfig(type: .fullWebsite, identifier: "u", dailyLimit: 20,
                           options: .fullWebsite(WebsiteOptions()), collectedToday: 0),
                           credentials: .init(), store: store)
            }
            override func fetchEntries() async throws -> [FeedEntry] { e }
            override func fetchArticleHTML(_ url: String) async throws -> String {
                if url == "https://x.com/1" {
                    return "<html><body><article><p>Full body one</p></article></body></html>"
                }
                throw URLError(.cancelled)                            // cancellation hits the second entry
            }
        }
        let entries = [
            FeedEntry(title: "One", link: "https://x.com/1", content: "<p>feed one</p>", summary: "<p>feed one</p>",
                      entryDescription: nil, published: .now, author: "", enclosures: [], itunesDuration: nil,
                      itunesImage: nil, mediaThumbnails: []),
            FeedEntry(title: "Two", link: "https://x.com/2", content: "<p>feed two</p>", summary: "<p>feed two</p>",
                      entryDescription: nil, published: .now, author: "", enclosures: [], itunesDuration: nil,
                      itunesImage: nil, mediaThumbnails: [])
        ]
        let agg = HalfCancelledFetch(entries, tempStore())
        let articles = try await agg.aggregate()
        #expect(articles.count == 1)
        #expect(articles.first?.identifier == "https://x.com/1")
        #expect(articles.first?.content.contains("Full body one") == true)   // fully scraped, not feed-only
    }
}
