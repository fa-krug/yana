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
}
