import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("MactechnewsAggregator")
struct MactechnewsAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry() -> FeedEntry {
        FeedEntry(title: "Mtn story", link: "https://www.mactechnews.de/news/article/Title-1.html",
                  content: "<p>s</p>", summary: "<p>s</p>", entryDescription: nil, published: .now,
                  author: "", enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubMtn: MactechnewsAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        var requestedFeedURL: String?
        init(entries: [FeedEntry], page: String, store: ImageStore) {
            self.entries = entries; self.page = page
            // Note: identifier deliberately wrong to prove the feed is forced.
            super.init(config: FeedConfig(type: .mactechnews, identifier: "https://wrong.example.com/feed",
                                          dailyLimit: 20, options: .mactechnews(MactechnewsOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchFeedData(_ url: String) async throws -> Data {
            requestedFeedURL = url
            let rss = """
            <?xml version="1.0"?><rss version="2.0"><channel><item>\
            <title>Mtn story</title><link>https://www.mactechnews.de/news/article/Title-1.html</link>\
            <description><![CDATA[<p>s</p>]]></description></item></channel></rss>
            """
            return Data(rss.utf8)
        }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func forcesNewsFeedRegardlessOfIdentifier() async throws {
        let agg = StubMtn(entries: [], page: "", store: tempStore())
        _ = try await agg.aggregate()
        #expect(agg.requestedFeedURL == "https://www.mactechnews.de/Rss/News.x")
    }

    @Test func extractsMtnArticleAndDedupsNumericImageID() async throws {
        // header image (og) Cover-X.592736.jpg; content has Bild.592736.jpg (same ID) + Other.111111.jpg.
        let page = """
        <html><head><meta property="og:image" content="https://www.mactechnews.de/img/Cover-X.592736.jpg"></head>
        <body><div class="MtnArticle"><p>Body</p>\
        <img src="/img/Bild.592736.jpg">\
        <img src="/img/Other.111111.jpg"></div></body></html>
        """
        final class StubAggregator: MactechnewsAggregator, @unchecked Sendable {
            let page: String
            init(_ page: String, _ store: ImageStore) {
                self.page = page
                super.init(config: FeedConfig(type: .mactechnews, identifier: "",
                           dailyLimit: 20, options: .mactechnews(MactechnewsOptions()), collectedToday: 0),
                           credentials: .init(), store: store)
            }
            override func fetchEntries() async throws -> [FeedEntry] {
                [FeedEntry(title: "T", link: "https://www.mactechnews.de/news/a.html", content: "<p>s</p>",
                           summary: nil, entryDescription: nil, published: .now, author: "", enclosures: [],
                           itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])]
            }
            override func fetchArticleHTML(_ url: String) async throws -> String { page }
            // Inject a header element with the og image so dedup runs.
            override func makeHeaderImageURL(forPage html: String) -> String? {
                "https://www.mactechnews.de/img/Cover-X.592736.jpg"
            }
        }
        let agg = StubAggregator(page, tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Body"))
        #expect(!a.content.contains("592736"))           // duplicate numeric-ID image removed
        #expect(a.content.contains("111111") || a.content.contains("\(ReaderWeb.imageScheme)://"))  // other image kept/localized
        let imgCount = a.content.components(separatedBy: "<img").count - 1
        #expect(imgCount == 1)   // duplicate-ID image removed; only the distinct-ID image survives
    }
}
