import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("RedditAggregator")
struct RedditAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private let tokenJSON = #"{"access_token":"TKN"}"#
    // Use a recent timestamp (now minus 1 day) so fixtures pass the implementation's
    // Date()-relative two-month retention filter regardless of the wall-clock date.
    private let recentUTC = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
    private var listingJSON: String {
        """
        {"data":{"children":[
          {"data":{"id":"p1","title":"Hello","selftext":"Body **bold** [docs](https://e.com/d)",
                   "url":"https://i.redd.it/pic.png","permalink":"/r/swift/comments/p1/hello/",
                   "created_utc":\(recentUTC),"author":"alice","score":42,"num_comments":7,"is_self":false}},
          {"data":{"id":"am","title":"Pinned","selftext":"","url":"","permalink":"/r/swift/comments/am/p/",
                   "created_utc":\(recentUTC),"author":"AutoModerator","score":1,"num_comments":99,"is_self":true}},
          {"data":{"id":"lc","title":"Few comments","selftext":"x","url":"","permalink":"/r/swift/comments/lc/p/",
                   "created_utc":\(recentUTC),"author":"carol","score":1,"num_comments":1,"is_self":true}}
        ]}}
        """
    }
    private let commentsJSON = """
    [ {"data":{"children":[]}},
      {"data":{"children":[
        {"kind":"t1","data":{"id":"c1","body":"Great post","author":"bob","score":10,"permalink":"/r/swift/comments/p1/hello/c1/"}}
      ]}} ]
    """

    private func makeAggregator(options: RedditOptions = RedditOptions()) -> RedditAggregator {
        var opts = options
        opts.minComments = 5      // p1=7 keeps, lc=1 drops
        opts.minAgeHours = 0      // disable age filter for deterministic fixture dates
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(self.commentsJSON.utf8) }
            return Data(self.listingJSON.utf8)
        }
        return RedditAggregator(config: config, credentials: creds, store: tempStore(), client: client)
    }

    @Test func filtersAutoModeratorAndLowComments() async throws {
        let articles = try await makeAggregator().aggregate()
        #expect(articles.count == 1)
        #expect(articles.first?.title == "Hello")
        #expect(articles.first?.author == "alice")
    }

    @Test func buildsContentWithMarkdownCommentsAndFooter() async throws {
        let a = try #require(try await makeAggregator().aggregate().first)
        #expect(a.content.contains("<strong>bold</strong>"))      // selftext markdown
        #expect(a.content.contains("Great post"))                 // comment body
        #expect(a.content.contains("<blockquote"))                // comment markup
        #expect(a.content.contains("<strong>bob</strong>"))       // comment author
        #expect(!a.content.contains("Source:"))                   // source link lives in the toolbar now
        #expect(a.identifier == "https://reddit.com/r/swift/comments/p1/hello/")
    }

    @Test func headerImageLocalizedAndDedupedFromBody() async throws {
        let a = try #require(try await makeAggregator().aggregate().first)
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))   // header image cached
        #expect(!a.content.contains("https://i.redd.it/pic.png"))     // remote url removed
    }

    /// A cancelled run (expired background-refresh window) surfaces as `URLError.cancelled` from a
    /// per-post comment fetch. The old `try?` swallowed it and persisted a comment-less post;
    /// now cancellation propagates so the partial build is dropped and the run stops cleanly,
    /// returning only fully-fetched posts (here, none) instead of degraded content.
    @Test func cancellationMidBuildDropsPartialPost() async throws {
        var opts = RedditOptions()
        opts.minComments = 0
        opts.minAgeHours = 0
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { throw URLError(.cancelled) }   // cancelled mid-build
            return Data(self.listingJSON.utf8)
        }
        let agg = RedditAggregator(config: config, credentials: creds, store: tempStore(), client: client)
        let articles = try await agg.aggregate()
        #expect(articles.isEmpty)                                          // no comment-less post persisted
    }

    @Test func missingCredentialsThrows() async {
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(RedditOptions()), collectedToday: 0)
        let agg = RedditAggregator(config: config, credentials: .init(), store: tempStore(), client: nil)
        await #expect(throws: AggregatorError.self) { try await agg.aggregate() }
    }

    // MARK: - Twitter/X selftext header tests

    /// A self-post whose selftext contains a Twitter/X status URL should use that URL
    /// as the header (Priority 0.6), bypassing the thumbnail fallback.
    @Test func selftextTwitterURLUsedAsHeader() async throws {
        let twitterURL = "https://x.com/u/status/123"
        let twitterListingJSON = """
        {"data":{"children":[
          {"data":{"id":"tx1","title":"Tweet post","selftext":"REASON: \(twitterURL)",
                   "url":"https://www.reddit.com/r/swift/comments/tx1/tweet_post/",
                   "permalink":"/r/swift/comments/tx1/tweet_post/",
                   "created_utc":\(recentUTC),"author":"alice","score":50,"num_comments":10,
                   "is_self":true,"is_gallery":false,"is_video":false,
                   "thumbnail":"https://example.com/thumb.jpg"}}
        ]}}
        """
        var opts = RedditOptions()
        opts.minComments = 5
        opts.minAgeHours = 0
        // includeHeaderImage = true so makeHeaderHTML is called; the Twitter embed path
        // calls EmbedRewriter.tweetEmbedHTML which hits the network and returns nil in tests
        // (no real fxtwitter server), so makeHeaderHTML returns "".  What matters is that
        // the thumbnail URL is NOT selected as the header instead.
        opts.includeHeaderImage = true
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(self.commentsJSON.utf8) }
            return Data(twitterListingJSON.utf8)
        }
        let agg = RedditAggregator(config: config, credentials: creds, store: tempStore(), client: client)
        let articles = try await agg.aggregate()
        let a = try #require(articles.first)
        // The thumbnail URL must NOT be selected as the header (Twitter URL takes priority)
        #expect(!a.content.contains("example.com/thumb.jpg"))
        // The article should aggregate successfully
        #expect(a.title == "Tweet post")
    }

    /// mobile.twitter.com status URLs must be recognised as Twitter URLs (server parity).
    @Test func mobileTwitterURLRecognised() async throws {
        let mobileURL = "https://mobile.twitter.com/user/status/9876543210"
        let listingJSON = """
        {"data":{"children":[
          {"data":{"id":"mt1","title":"Mobile tweet","selftext":"See \(mobileURL)",
                   "url":"https://www.reddit.com/r/swift/comments/mt1/mobile_tweet/",
                   "permalink":"/r/swift/comments/mt1/mobile_tweet/",
                   "created_utc":\(recentUTC),"author":"carol","score":50,"num_comments":10,
                   "is_self":true,"is_gallery":false,"is_video":false,
                   "thumbnail":"https://example.com/thumb2.jpg"}}
        ]}}
        """
        var opts = RedditOptions(); opts.minComments = 5; opts.minAgeHours = 0; opts.includeHeaderImage = true
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(self.commentsJSON.utf8) }
            return Data(listingJSON.utf8)
        }
        let agg = RedditAggregator(config: config, credentials: creds, store: tempStore(), client: client)
        let articles = try await agg.aggregate()
        let a = try #require(articles.first)
        #expect(!a.content.contains("example.com/thumb2.jpg"), "mobile.twitter.com URL should take header priority over thumbnail")
    }

    /// Force reload sets `dailyLimit = Int.max` (FeedConfig.init(feed:force:)). The fetch-limit
    /// computation `limit * 3` must not overflow — it previously crashed with an arithmetic
    /// overflow trap when force-reloading a Reddit feed.
    @Test func forceReloadDailyLimitDoesNotOverflow() async throws {
        var opts = RedditOptions()
        opts.minComments = 5
        opts.minAgeHours = 0
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: Int.max,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(self.commentsJSON.utf8) }
            return Data(self.listingJSON.utf8)
        }
        let agg = RedditAggregator(config: config, credentials: creds, store: tempStore(), client: client)
        let articles = try await agg.aggregate()
        #expect(articles.count == 1)
    }

    @Test func logoImageURLReturnsSubredditIcon() async {
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(RedditOptions()), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { req in
            let url = req.url!.absoluteString
            if url.contains("access_token") { return Data(#"{"access_token":"T"}"#.utf8) }
            return Data(#"{"data":{"community_icon":"https://r/icon.png"}}"#.utf8)
        }
        let agg = RedditAggregator(config: config, credentials: creds, store: tempStore(), client: client)
        #expect(await agg.logoImageURL() == "https://r/icon.png")
    }

    @Test func logoImageURLNilWithoutCredentials() async {
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(RedditOptions()), collectedToday: 0)
        let agg = RedditAggregator(config: config, credentials: .init(), store: tempStore(), client: nil)
        #expect(await agg.logoImageURL() == nil)
    }

    /// A self-post with a plain image URL in selftext (no Twitter/X URL) should not be
    /// affected by the new Priority 0.6 check — preview/thumbnail still applies as before.
    @Test func selftextPlainImageLinkUnaffected() async throws {
        let imageListingJSON = """
        {"data":{"children":[
          {"data":{"id":"img1","title":"Image post","selftext":"Check this out https://i.redd.it/cool.png",
                   "url":"https://www.reddit.com/r/swift/comments/img1/image_post/",
                   "permalink":"/r/swift/comments/img1/image_post/",
                   "created_utc":\(recentUTC),"author":"bob","score":50,"num_comments":10,
                   "is_self":true,"is_gallery":false,"is_video":false,
                   "preview":{"images":[{"source":{"url":"https://preview.redd.it/cool.png?width=640"}}]}}}
        ]}}
        """
        var opts = RedditOptions()
        opts.minComments = 5
        opts.minAgeHours = 0
        opts.includeHeaderImage = true
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(self.commentsJSON.utf8) }
            return Data(imageListingJSON.utf8)
        }
        let agg = RedditAggregator(config: config, credentials: creds, store: tempStore(), client: client)
        let articles = try await agg.aggregate()
        // Should aggregate without error; preview image used as header (cached via ImageStore)
        #expect(articles.count == 1)
        #expect(articles.first?.title == "Image post")
        // Header image should be cached (yana-image:// scheme in content)
        #expect(articles.first?.content.contains("\(ReaderWeb.imageScheme)://") == true)
    }

    // MARK: - Header-image priority parity with the server (extract_header_image_url)

    /// Records every URL the ImageStore is asked to download, so a test can assert *which*
    /// candidate became the header (the remote URL is otherwise localized away in the content).
    private final class FetchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [String] = []
        var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
        func add(_ u: String) { lock.lock(); _urls.append(u); lock.unlock() }
    }

    private func recordingStore(_ rec: FetchRecorder) -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { url in rec.add(url.absoluteString); return (png, "image/png") })
    }

    private func aggregator(listing: String, store: ImageStore,
                            pageFetch: @escaping @Sendable (URL) async throws -> String = { _ in "" }) -> RedditAggregator {
        var opts = RedditOptions(); opts.minComments = 5; opts.minAgeHours = 0; opts.includeHeaderImage = true
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(self.commentsJSON.utf8) }
            return Data(listing.utf8)
        }
        return RedditAggregator(config: config, credentials: creds, store: store, client: client, pageFetch: pageFetch)
    }

    /// Priority 0.5: a link post whose URL *is* a Twitter/X status (not in selftext) must use that
    /// URL as the header, never the thumbnail. (Server extract_header_image_url Priority 0.5.)
    @Test func twitterLinkPostUsedAsHeaderOverThumbnail() async throws {
        let rec = FetchRecorder()
        let listing = """
        {"data":{"children":[
          {"data":{"id":"tl1","title":"Tweet link","selftext":"",
                   "url":"https://x.com/u/status/555","permalink":"/r/swift/comments/tl1/tweet_link/",
                   "created_utc":\(recentUTC),"author":"dave","score":50,"num_comments":10,
                   "is_self":false,"is_gallery":false,"is_video":false,
                   "thumbnail":"https://example.com/thumb.jpg"}}
        ]}}
        """
        _ = try await aggregator(listing: listing, store: recordingStore(rec)).aggregate()
        #expect(!rec.urls.contains("https://example.com/thumb.jpg"),
                "thumbnail must not be fetched as header when the post URL is a tweet")
    }

    /// Priority 3: a self-post with a preview.redd.it image link in its selftext (and no top-level
    /// preview field) must promote that image to the header, not the low-res thumbnail.
    @Test func selftextImageLinkPromotedToHeader() async throws {
        let rec = FetchRecorder()
        let listing = """
        {"data":{"children":[
          {"data":{"id":"se1","title":"Selftext image","selftext":"Look: https://preview.redd.it/x.png",
                   "url":"https://www.reddit.com/r/swift/comments/se1/selftext_image/",
                   "permalink":"/r/swift/comments/se1/selftext_image/",
                   "created_utc":\(recentUTC),"author":"erin","score":50,"num_comments":10,
                   "is_self":true,"is_gallery":false,"is_video":false,
                   "thumbnail":"https://example.com/thumb.jpg"}}
        ]}}
        """
        _ = try await aggregator(listing: listing, store: recordingStore(rec)).aggregate()
        #expect(rec.urls.contains("https://preview.redd.it/x.png"),
                "selftext image should be promoted to the header")
        #expect(!rec.urls.contains("https://example.com/thumb.jpg"),
                "thumbnail must not win over a selftext image")
    }

    /// Priority 5: a link post with no Reddit preview/thumbnail must fall back to the linked page's
    /// og:image. (Server extract_header_image_url Priority 5 / link-page scraping.)
    @Test func linkPostScrapesOgImageWhenNoPreview() async throws {
        let rec = FetchRecorder()
        let listing = """
        {"data":{"children":[
          {"data":{"id":"lp1","title":"Article link","selftext":"",
                   "url":"https://news.example.com/article","permalink":"/r/swift/comments/lp1/article_link/",
                   "created_utc":\(recentUTC),"author":"frank","score":50,"num_comments":10,
                   "is_self":false,"is_gallery":false,"is_video":false,"thumbnail":"default"}}
        ]}}
        """
        let page = #"<html><head><meta property="og:image" content="https://cdn.example.com/lead.jpg"></head><body>x</body></html>"#
        _ = try await aggregator(listing: listing, store: recordingStore(rec), pageFetch: { _ in page }).aggregate()
        #expect(rec.urls.contains("https://cdn.example.com/lead.jpg"),
                "og:image from the linked page should become the header when Reddit has no preview")
    }

    // MARK: - refetch

    private func makeRefetchAggregator() -> RedditAggregator {
        var opts = RedditOptions(); opts.minComments = 0; opts.minAgeHours = 0
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let postJSON = """
        [ {"data":{"children":[
            {"data":{"id":"p1","title":"Hello refreshed","selftext":"Fresh **body**","url":"",
                     "permalink":"/r/swift/comments/p1/hello/","created_utc":\(recentUTC),
                     "author":"alice","score":42,"num_comments":7,"is_self":true}}
          ]}},
          {"data":{"children":[
            {"kind":"t1","data":{"id":"c1","body":"Great post","author":"bob","score":10,"permalink":"/r/swift/comments/p1/hello/c1/"}}
          ]}} ]
        """
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            return Data(postJSON.utf8)   // both /comments fetches (post + comments) hit this
        }
        return RedditAggregator(config: config, credentials: creds, store: tempStore(), client: client)
    }

    @Test func refetchRebuildsSinglePost() async throws {
        let seed = AggregatedArticle(title: "Old", identifier: "https://reddit.com/r/swift/comments/p1/hello/",
                                     url: "https://reddit.com/r/swift/comments/p1/hello/",
                                     rawContent: "", content: "OLD", date: .now, author: "alice", iconURL: nil)
        let a = try #require(try await makeRefetchAggregator().refetch(seed))
        #expect(a.identifier == "https://reddit.com/r/swift/comments/p1/hello/")
        #expect(a.content.contains("<strong>body</strong>"))   // refreshed selftext markdown
        #expect(a.content.contains("Great post"))               // comments rebuilt
    }

    @Test func refetchReturnsNilForUnparseablePermalink() async throws {
        let seed = AggregatedArticle(title: "x", identifier: "https://reddit.com/r/swift/",
                                     url: "https://reddit.com/r/swift/",
                                     rawContent: "", content: "", date: .now, author: "", iconURL: nil)
        let result = try await makeRefetchAggregator().refetch(seed)
        #expect(result == nil)
    }

    /// Priority 3 truncation: an image link that appears *after* a referenced comment URL in the
    /// selftext belongs to the quoted discussion, not this post — so it must not be promoted to the
    /// header. The chain falls back to the thumbnail instead. (Server _extract_image_url_from_selftext.)
    @Test func selftextImageAfterCommentURLIsNotPromoted() async throws {
        let rec = FetchRecorder()
        let listing = """
        {"data":{"children":[
          {"data":{"id":"ct1","title":"Quoted thread",
                   "selftext":"As discussed https://www.reddit.com/r/swift/comments/ab12/title/cd34 see https://preview.redd.it/after.png",
                   "url":"https://www.reddit.com/r/swift/comments/ct1/quoted_thread/",
                   "permalink":"/r/swift/comments/ct1/quoted_thread/",
                   "created_utc":\(recentUTC),"author":"gwen","score":50,"num_comments":10,
                   "is_self":true,"is_gallery":false,"is_video":false,
                   "thumbnail":"https://example.com/thumb.jpg"}}
        ]}}
        """
        let a = try #require(try await aggregator(listing: listing, store: recordingStore(rec)).aggregate().first)
        // The header-selection chain returns exactly one URL, so the thumbnail being fetched as the
        // header proves the post-comment selftext image was NOT promoted to the header.
        #expect(rec.urls.contains("https://example.com/thumb.jpg"),
                "with the post-comment image excluded, the chain falls back to the thumbnail")
        // The quoted-thread image still renders inline in the body — now localized like every other
        // inline image (downloaded and rewritten to a cached reference), just never as the header.
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))
        #expect(!a.content.contains("https://preview.redd.it/after.png"),
                "the inline image is localized to a cached reference, not left as a remote URL")
    }

    // MARK: - Reddit-hosted video

    /// A native `v.redd.it` video post must embed an inline HTML5 player using the HLS stream
    /// (audio + inline playback in WKWebView), with the Reddit preview image as the poster.
    @Test func hostedVideoPostEmbedsInlinePlayer() async throws {
        let rec = FetchRecorder()
        let listing = """
        {"data":{"children":[
          {"data":{"id":"v1","title":"Hosted video","selftext":"",
                   "url":"https://v.redd.it/abc123","permalink":"/r/swift/comments/v1/hosted_video/",
                   "created_utc":\(recentUTC),"author":"vic","score":50,"num_comments":10,
                   "is_self":false,"is_gallery":false,"is_video":true,
                   "thumbnail":"https://example.com/thumb.jpg",
                   "preview":{"images":[{"source":{"url":"https://preview.redd.it/poster.jpg?width=640"}}]},
                   "media":{"reddit_video":{"hls_url":"https://v.redd.it/abc123/HLSPlaylist.m3u8?a=1&amp;b=2",
                                            "fallback_url":"https://v.redd.it/abc123/DASH_720.mp4"}}}}
        ]}}
        """
        let a = try #require(try await aggregator(listing: listing, store: recordingStore(rec)).aggregate().first)
        #expect(a.content.contains("<video"))
        #expect(a.content.contains("playsinline"))
        #expect(a.content.contains("https://v.redd.it/abc123/HLSPlaylist.m3u8?a=1&b=2"),
                "the HLS stream URL (entity-decoded) must be the player source")
        #expect(a.content.contains("application/vnd.apple.mpegurl"))
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"), "poster image must be localized")
        #expect(rec.urls.contains("https://preview.redd.it/poster.jpg?width=640"),
                "the preview image must be cached as the video poster")
    }

    /// Regression: a *crosspost* of a video post. Reddit omits `media`/`preview` from the nested
    /// `crosspost_parent_list` entry the article is built from — that media lives on the outer
    /// wrapper. The player (and poster) must fall back to the outer post so the article isn't
    /// left with no media at all (the reported "missing image" bug).
    @Test func crosspostVideoFallsBackToOuterWrapperMedia() async throws {
        let rec = FetchRecorder()
        let listing = """
        {"data":{"children":[
          {"data":{"id":"xp1","title":"Crosspost video","selftext":"",
                   "url":"https://v.redd.it/xyz","permalink":"/r/funny/comments/xp1/crosspost_video/",
                   "created_utc":\(recentUTC),"author":"sharer","score":50,"num_comments":10,
                   "is_self":false,"is_gallery":false,"is_video":true,
                   "thumbnail":"https://example.com/outerthumb.jpg",
                   "preview":{"images":[{"source":{"url":"https://preview.redd.it/outerposter.jpg"}}]},
                   "media":{"reddit_video":{"hls_url":"https://v.redd.it/xyz/HLSPlaylist.m3u8"}},
                   "crosspost_parent_list":[
                     {"id":"orig","title":"DIY elevator","selftext":"",
                      "url":"https://v.redd.it/xyz","permalink":"/r/TikTokCringe/comments/orig/diy_elevator/",
                      "created_utc":\(recentUTC),"author":"galaxystars1","score":99,"num_comments":50,
                      "is_self":false,"is_gallery":false,"is_video":true,"thumbnail":"spoiler"}]}}
        ]}}
        """
        let a = try #require(try await aggregator(listing: listing, store: recordingStore(rec)).aggregate().first)
        #expect(a.title == "DIY elevator")
        #expect(a.identifier == "https://reddit.com/r/TikTokCringe/comments/orig/diy_elevator/")
        #expect(a.content.contains("<video"), "the crosspost parent lacks media; the player must use the outer wrapper")
        #expect(a.content.contains("https://v.redd.it/xyz/HLSPlaylist.m3u8"))
        #expect(rec.urls.contains("https://preview.redd.it/outerposter.jpg"),
                "the poster must fall back to the outer wrapper's preview image")
    }

    // MARK: - Giphy link posts

    /// A Giphy *link post* — `url` is a giphy.com watch page (no file extension) — must render as
    /// the animated GIF, not a bare link. The watch URL is rewritten to the media-CDN GIF and
    /// localized like every other inline image.
    @Test func giphyLinkPostRendersAsImage() async throws {
        let rec = FetchRecorder()
        let listing = """
        {"data":{"children":[
          {"data":{"id":"gp1","title":"Funny gif","selftext":"",
                   "url":"https://giphy.com/gifs/funny-cat-l0MYt5jPR6QX5pnqM",
                   "permalink":"/r/funny/comments/gp1/funny_gif/",
                   "created_utc":\(recentUTC),"author":"gina","score":50,"num_comments":10,
                   "is_self":false,"is_gallery":false,"is_video":false,"thumbnail":"default"}}
        ]}}
        """
        let a = try #require(try await aggregator(listing: listing, store: recordingStore(rec)).aggregate().first)
        #expect(rec.urls.contains("https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif"),
                "the Giphy watch URL must be rewritten to the media-CDN GIF and downloaded")
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"), "the Giphy GIF must be localized")
        #expect(!a.content.contains("giphy.com/gifs/"), "the bare watch link must not survive")
    }

    /// A *crosspost* of a Giphy link post is the reported "nothing renders" case: the old
    /// `addLinkMedia` appended nothing for crossposts, so the GIF vanished entirely. It must now
    /// render the animated GIF from the crosspost parent's URL.
    @Test func giphyCrosspostRendersAsImage() async throws {
        let rec = FetchRecorder()
        let listing = """
        {"data":{"children":[
          {"data":{"id":"xg1","title":"Shared gif","selftext":"",
                   "url":"https://giphy.com/gifs/lol-l0MYt5jPR6QX5pnqM","permalink":"/r/funny/comments/xg1/shared_gif/",
                   "created_utc":\(recentUTC),"author":"sharer","score":50,"num_comments":10,
                   "is_self":false,"is_gallery":false,"is_video":false,"thumbnail":"default",
                   "crosspost_parent_list":[
                     {"id":"orig","title":"Original gif","selftext":"",
                      "url":"https://giphy.com/gifs/lol-l0MYt5jPR6QX5pnqM","permalink":"/r/gifs/comments/orig/original_gif/",
                      "created_utc":\(recentUTC),"author":"maker","score":99,"num_comments":50,
                      "is_self":false,"is_gallery":false,"is_video":false,"thumbnail":"default"}]}}
        ]}}
        """
        let a = try #require(try await aggregator(listing: listing, store: recordingStore(rec)).aggregate().first)
        #expect(rec.urls.contains("https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif"),
                "a crossposted Giphy link must still render as the media-CDN GIF")
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"), "the crossposted Giphy GIF must be localized")
    }

    // MARK: - Inline image localization

    /// Inline body images (here, an image inside a comment) must be downloaded and rewritten to
    /// cached `yana-img://` references like every other aggregator — the reader must never issue a
    /// remote image request. Reddit's CDN UA was never the problem; un-localized inline images were.
    @Test func inlineBodyImagesAreLocalized() async throws {
        let rec = FetchRecorder()
        // A self-post with no header image (empty selftext, `self` thumbnail), so the only image is
        // the one embedded in a comment body — which is never promoted to the header.
        let listing = """
        {"data":{"children":[
          {"data":{"id":"ib1","title":"Inline image","selftext":"",
                   "url":"https://www.reddit.com/r/swift/comments/ib1/inline_image/",
                   "permalink":"/r/swift/comments/ib1/inline_image/",
                   "created_utc":\(recentUTC),"author":"frank","score":50,"num_comments":10,
                   "is_self":true,"is_gallery":false,"is_video":false,"thumbnail":"self"}}
        ]}}
        """
        let comments = """
        [ {"data":{"children":[]}},
          {"data":{"children":[
            {"kind":"t1","data":{"id":"c1","body":"See https://preview.redd.it/c.png","author":"bob","score":10,"permalink":"/r/swift/comments/ib1/inline_image/c1/"}}
          ]}} ]
        """
        let store = recordingStore(rec)
        var opts = RedditOptions(); opts.minComments = 5; opts.minAgeHours = 0; opts.includeHeaderImage = true
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(comments.utf8) }
            return Data(listing.utf8)
        }
        let a = try #require(try await RedditAggregator(config: config, credentials: creds,
                                                        store: store, client: client).aggregate().first)
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"), "inline comment image must be localized")
        #expect(!a.content.contains("https://preview.redd.it/c.png"), "remote inline image URL must be replaced")
        #expect(rec.urls.contains("https://preview.redd.it/c.png"),
                "the inline image must be downloaded into the cache")
    }

    /// Gallery posts: `gallery_data.items[].media_id` (Reddit's snake_case key) must decode so the
    /// matching `media_metadata` entry resolves to an image URL. A plain JSONDecoder would leave
    /// `mediaID` nil and silently drop every gallery image.
    @Test func galleryImagesDecodeAndLocalize() async throws {
        let rec = FetchRecorder()
        let listing = """
        {"data":{"children":[
          {"data":{"id":"g1","title":"Gallery","selftext":"",
                   "url":"https://www.reddit.com/gallery/g1","permalink":"/r/pics/comments/g1/gallery/",
                   "created_utc":\(recentUTC),"author":"hank","score":50,"num_comments":10,
                   "is_self":false,"is_gallery":true,"is_video":false,
                   "gallery_data":{"items":[{"media_id":"AAA"},{"media_id":"BBB"}]},
                   "media_metadata":{
                     "AAA":{"e":"Image","s":{"u":"https://preview.redd.it/aaa.jpg?width=640"}},
                     "BBB":{"e":"Image","s":{"u":"https://preview.redd.it/bbb.jpg?width=640"}}}}}
        ]}}
        """
        let a = try #require(try await aggregator(listing: listing, store: recordingStore(rec)).aggregate().first)
        #expect(rec.urls.contains("https://preview.redd.it/aaa.jpg?width=640"),
                "first gallery image must decode (media_id → mediaID) and be downloaded as the header")
        #expect(rec.urls.contains("https://preview.redd.it/bbb.jpg?width=640"),
                "second gallery image must decode and be localized inline")
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"), "gallery images must be localized")
    }
}
