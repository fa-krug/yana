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

    /// Full-featured stub used for multi-page and comment tests.
    final class StubMactechnews: MactechnewsAggregator, @unchecked Sendable {
        let firstPage: String
        let extraPages: [String: String]

        init(firstPage: String, extraPages: [String: String] = [:],
             options: MactechnewsOptions = MactechnewsOptions(), store: ImageStore) {
            self.firstPage = firstPage
            self.extraPages = extraPages
            super.init(
                config: FeedConfig(type: .mactechnews,
                                   identifier: "https://www.mactechnews.de/news/article/Title-1.html",
                                   dailyLimit: 20, options: .mactechnews(options), collectedToday: 0),
                credentials: .init(), store: store)
        }

        override func fetchEntries() async throws -> [FeedEntry] { [] }
        override func fetchArticleHTML(_ url: String) async throws -> String { firstPage }
        override func fetchAdditionalPage(_ url: String) async throws -> String { extraPages[url] ?? "" }
    }

    /// Drives a single article through enrich() with injected pages.
    private func enrichOne(_ agg: MactechnewsAggregator) async throws -> AggregatedArticle {
        let e = entry()
        let base = agg.makeArticle(from: e)
        return try await agg.enrich(base, entry: e)
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
        // Now that og:image produces a header image, we expect 2 images:
        // 1 header (yana-img:// from og:image) + 1 body (Other.111111.jpg localized).
        // Bild.592736.jpg is removed by numeric-ID dedup.
        #expect(imgCount == 2)
    }

    // MARK: - Pagination detection

    @Test func detectsPaginationFromQueryParamLinks() {
        let html = """
        <html><body><div class="MtnArticle"><p>Body</p>\
        <a href="https://www.mactechnews.de/news/article/Title-1.html?page=2">2</a>\
        <a href="https://www.mactechnews.de/news/article/Title-1.html?page=3">3</a>\
        </div></body></html>
        """
        let agg = StubMactechnews(firstPage: html, store: tempStore())
        let pages = agg.detectPagination(html: html)
        #expect(pages == [1, 2, 3])
    }

    @Test func detectsPaginationFromAmpersandPageParam() {
        // &page=N variant (URL already has other query params)
        let html = """
        <html><body><div class="MtnArticle"><p>Body</p>\
        <a href="https://www.mactechnews.de/news/article/Title-1.html?foo=bar&page=2">2</a>\
        </div></body></html>
        """
        let agg = StubMactechnews(firstPage: html, store: tempStore())
        let pages = agg.detectPagination(html: html)
        #expect(pages.contains(1))
        #expect(pages.contains(2))
    }

    @Test func detectsCurrentPageAsStrongElement() {
        // Current page rendered as <strong>N</strong> without a link (server fix 4099b10).
        let html = """
        <html><body><div class="MtnArticle"><p>Body</p>\
        <strong>1</strong>\
        <a href="https://www.mactechnews.de/news/article/Title-1.html?page=2">2</a>\
        <a href="https://www.mactechnews.de/news/article/Title-1.html?page=3">3</a>\
        </div></body></html>
        """
        let agg = StubMactechnews(firstPage: html, store: tempStore())
        let pages = agg.detectPagination(html: html)
        #expect(pages == [1, 2, 3])
    }

    @Test func noPaginationForSinglePage() {
        let html = "<html><body><div class=\"MtnArticle\"><p>Single page</p></div></body></html>"
        let agg = StubMactechnews(firstPage: html, store: tempStore())
        let pages = agg.detectPagination(html: html)
        #expect(pages == [1])
    }

    @Test func alwaysIncludesPageOne() {
        // Even if page=1 link is not present, page 1 is always in the result.
        let html = """
        <html><body><div class="MtnArticle"><p>Body</p>\
        <a href="?page=2">2</a></div></body></html>
        """
        let agg = StubMactechnews(firstPage: html, store: tempStore())
        let pages = agg.detectPagination(html: html)
        #expect(pages.contains(1))
    }

    // MARK: - Multi-page combining

    @Test func combinesPagesWhenEnabled() async throws {
        // First page has a ?page=2 link; second page has different content.
        let articleURL = "https://www.mactechnews.de/news/article/Title-1.html"
        let page2URL = "\(articleURL)?page=2"
        let first = """
        <html><body><div class="MtnArticle"><p>Page one body</p>\
        <a href="\(page2URL)">2</a></div></body></html>
        """
        let page2 = "<html><body><div class=\"MtnArticle\"><p>Page two body</p></div></body></html>"
        let opts = MactechnewsOptions(combinePages: true, includeComments: false, maxComments: 0)
        let agg = StubMactechnews(firstPage: first, extraPages: [page2URL: page2],
                                   options: opts, store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Page one body"))
        #expect(a.content.contains("Page two body"))
    }

    @Test func disablingCombineKeepsFirstPageOnly() async throws {
        let articleURL = "https://www.mactechnews.de/news/article/Title-1.html"
        let page2URL = "\(articleURL)?page=2"
        let first = """
        <html><body><div class="MtnArticle"><p>Only page one</p>\
        <a href="\(page2URL)">2</a></div></body></html>
        """
        let page2 = "<html><body><div class=\"MtnArticle\"><p>Page two body</p></div></body></html>"
        let opts = MactechnewsOptions(combinePages: false, includeComments: false, maxComments: 0)
        let agg = StubMactechnews(firstPage: first, extraPages: [page2URL: page2],
                                   options: opts, store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Only page one"))
        #expect(!a.content.contains("Page two body"))
    }

    @Test func multiPageWithStrongCurrentPageDetection() async throws {
        // Current page as <strong>1</strong>, next page via query link (4099b10 fix).
        let articleURL = "https://www.mactechnews.de/news/article/Title-1.html"
        let page2URL = "\(articleURL)?page=2"
        let first = """
        <html><body><div class="MtnArticle"><p>First page content</p>\
        <strong>1</strong>\
        <a href="\(page2URL)">2</a></div></body></html>
        """
        let page2 = "<html><body><div class=\"MtnArticle\"><p>Second page content</p></div></body></html>"
        let opts = MactechnewsOptions(combinePages: true, includeComments: false, maxComments: 0)
        let agg = StubMactechnews(firstPage: first, extraPages: [page2URL: page2],
                                   options: opts, store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("First page content"))
        #expect(a.content.contains("Second page content"))
    }

    // MARK: - Comment extraction

    @Test func extractsCommentsWhenEnabled() async throws {
        let articleURL = "https://www.mactechnews.de/news/article/Title-1.html"
        let pageWithComments = """
        <html><body>
        <div class="MtnArticle"><p>Article body</p></div>
        <div class="MtnCommentScroll">
          <div class="MtnComment" id="comment-1">
            <span class="MtnCommentAccountName">Alice</span>
            <span class="MtnCommentTime"><span>10.06.2026</span><span>14:00</span></span>
            <div class="MtnCommentText"><p>Great article!</p></div>
          </div>
          <div class="MtnComment" id="comment-2">
            <span class="MtnCommentAccountName">Bob</span>
            <span class="MtnCommentTime"><span>10.06.2026</span><span>15:00</span></span>
            <div class="MtnCommentText"><p>I agree.</p></div>
          </div>
        </div>
        </body></html>
        """
        let opts = MactechnewsOptions(combinePages: false, includeComments: true, maxComments: 5)
        let agg = StubMactechnews(firstPage: pageWithComments, options: opts, store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Alice"))
        #expect(a.content.contains("Bob"))
        #expect(a.content.contains("Great article!"))
        #expect(a.content.contains("I agree."))
        #expect(a.content.contains("Comments"))
    }

    @Test func respectsMaxComments() async throws {
        let pageWithComments = """
        <html><body>
        <div class="MtnArticle"><p>Body</p></div>
        <div class="MtnCommentScroll">
          <div class="MtnComment" id="c1">
            <span class="MtnCommentAccountName">User1</span>
            <div class="MtnCommentText"><p>Comment 1</p></div>
          </div>
          <div class="MtnComment" id="c2">
            <span class="MtnCommentAccountName">User2</span>
            <div class="MtnCommentText"><p>Comment 2</p></div>
          </div>
          <div class="MtnComment" id="c3">
            <span class="MtnCommentAccountName">User3</span>
            <div class="MtnCommentText"><p>Comment 3</p></div>
          </div>
        </div>
        </body></html>
        """
        let opts = MactechnewsOptions(combinePages: false, includeComments: true, maxComments: 2)
        let agg = StubMactechnews(firstPage: pageWithComments, options: opts, store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Comment 1"))
        #expect(a.content.contains("Comment 2"))
        #expect(!a.content.contains("Comment 3"))   // capped at maxComments=2
    }

    @Test func noCommentsWhenDisabled() async throws {
        let pageWithComments = """
        <html><body>
        <div class="MtnArticle"><p>Article text</p></div>
        <div class="MtnCommentScroll">
          <div class="MtnComment" id="c1">
            <span class="MtnCommentAccountName">Alice</span>
            <div class="MtnCommentText"><p>Should be hidden</p></div>
          </div>
        </div>
        </body></html>
        """
        let opts = MactechnewsOptions(combinePages: false, includeComments: false, maxComments: 5)
        let agg = StubMactechnews(firstPage: pageWithComments, options: opts, store: tempStore())
        let a = try await enrichOne(agg)
        #expect(!a.content.contains("Should be hidden"))
        #expect(!a.content.contains("Alice"))
    }

    @Test func noCommentsWhenMaxCommentsIsZero() async throws {
        let pageWithComments = """
        <html><body>
        <div class="MtnArticle"><p>Body</p></div>
        <div class="MtnCommentScroll">
          <div class="MtnComment" id="c1">
            <span class="MtnCommentAccountName">Alice</span>
            <div class="MtnCommentText"><p>Hidden comment</p></div>
          </div>
        </div>
        </body></html>
        """
        let opts = MactechnewsOptions(combinePages: false, includeComments: true, maxComments: 0)
        let agg = StubMactechnews(firstPage: pageWithComments, options: opts, store: tempStore())
        let a = try await enrichOne(agg)
        #expect(!a.content.contains("Hidden comment"))
    }

    @Test func commentAnchorURLBuiltFromElementID() async throws {
        let articleURL = "https://www.mactechnews.de/news/article/Title-1.html"
        let pageWithComments = """
        <html><body>
        <div class="MtnArticle"><p>Body</p></div>
        <div class="MtnCommentScroll">
          <div class="MtnComment" id="comment-42">
            <span class="MtnCommentAccountName">Alice</span>
            <div class="MtnCommentText"><p>Text</p></div>
          </div>
        </div>
        </body></html>
        """
        let opts = MactechnewsOptions(combinePages: false, includeComments: true, maxComments: 5)
        let agg = StubMactechnews(firstPage: pageWithComments, options: opts, store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("\(articleURL)#comment-42"))
    }
}
