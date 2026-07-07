import Foundation
import UIKit
import Testing
@testable import Yana

// MARK: - Helpers

private func jsonBytes(_ obj: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: obj)
}

/// Builds a @Sendable two-step fetcher (resolveHandle → getPosts) from pre-serialised bytes.
private func makeFetch(postData: Data, didString: String = "did:plc:test123") -> @Sendable (URLRequest) async throws -> Data {
    { req in
        if req.url?.path.contains("resolveHandle") == true {
            return jsonBytes(["did": didString])
        }
        return postData
    }
}

// MARK: - Suite

@Suite("BlueskyEmbed")
struct BlueskyEmbedTests {

    // MARK: - URL detection

    @Test func isBlueskyURL_positive() {
        #expect(BlueskyEmbed.isBlueskyURL("https://bsky.app/profile/user.bsky.social/post/abc123"))
        #expect(BlueskyEmbed.isBlueskyURL("https://staging.bsky.app/profile/user/post/abc"))
    }

    @Test func isBlueskyURL_negative() {
        #expect(!BlueskyEmbed.isBlueskyURL("https://x.com/user/status/123"))
        #expect(!BlueskyEmbed.isBlueskyURL("https://example.com"))
        #expect(!BlueskyEmbed.isBlueskyURL(""))
    }

    // MARK: - Post info extraction

    @Test func extractPostInfo_handle() {
        let result = BlueskyEmbed.extractPostInfo(from: "https://bsky.app/profile/stirpicus.bsky.social/post/3mngsbu7t2s27")
        #expect(result?.actor == "stirpicus.bsky.social")
        #expect(result?.rkey  == "3mngsbu7t2s27")
    }

    @Test func extractPostInfo_did() {
        let result = BlueskyEmbed.extractPostInfo(from: "https://bsky.app/profile/did:plc:abc123/post/3mngsbu7t2s27")
        #expect(result?.actor == "did:plc:abc123")
        #expect(result?.rkey  == "3mngsbu7t2s27")
    }

    @Test func extractPostInfo_stripsQueryString() {
        let result = BlueskyEmbed.extractPostInfo(from: "https://bsky.app/profile/user.bsky.social/post/abc123?foo=bar")
        #expect(result?.actor == "user.bsky.social")
        #expect(result?.rkey  == "abc123")
    }

    @Test func extractPostInfo_invalidURLs() {
        #expect(BlueskyEmbed.extractPostInfo(from: "https://bsky.app/profile/user.bsky.social") == nil)
        #expect(BlueskyEmbed.extractPostInfo(from: "https://example.com/not-a-post") == nil)
        #expect(BlueskyEmbed.extractPostInfo(from: "") == nil)
    }

    // MARK: - Image extraction

    @Test func extractImageURLs_imagesView() {
        let post: [String: Any] = [
            "embed": [
                "$type": "app.bsky.embed.images#view",
                "images": [
                    ["fullsize": "https://cdn.bsky.app/img/1.jpg", "thumb": "t1"],
                    ["fullsize": "https://cdn.bsky.app/img/2.jpg", "thumb": "t2"],
                ],
            ]
        ]
        let urls = BlueskyEmbed.extractImageURLs(from: post)
        #expect(urls == ["https://cdn.bsky.app/img/1.jpg", "https://cdn.bsky.app/img/2.jpg"])
    }

    @Test func extractImageURLs_recordWithMedia() {
        let post: [String: Any] = [
            "embed": [
                "$type": "app.bsky.embed.recordWithMedia#view",
                "media": [
                    "$type": "app.bsky.embed.images#view",
                    "images": [["fullsize": "https://cdn.bsky.app/img/1.jpg"]],
                ],
            ]
        ]
        let urls = BlueskyEmbed.extractImageURLs(from: post)
        #expect(urls == ["https://cdn.bsky.app/img/1.jpg"])
    }

    @Test func extractImageURLs_thumbFallback() {
        let post: [String: Any] = [
            "embed": [
                "$type": "app.bsky.embed.images#view",
                "images": [["thumb": "https://cdn.bsky.app/img/thumb.jpg"]],
            ]
        ]
        let urls = BlueskyEmbed.extractImageURLs(from: post)
        #expect(urls == ["https://cdn.bsky.app/img/thumb.jpg"])
    }

    @Test func extractImageURLs_noImages() {
        let urls = BlueskyEmbed.extractImageURLs(from: ["embed": ["$type": "app.bsky.embed.external#view"]])
        #expect(urls.isEmpty)
        #expect(BlueskyEmbed.extractImageURLs(from: [:]).isEmpty)
    }

    // MARK: - HTML helpers

    @Test func escapeHTML() {
        #expect(BlueskyEmbed.escapeHTML("<b>bold</b>") == "&lt;b&gt;bold&lt;/b&gt;")
        #expect(BlueskyEmbed.escapeHTML("a \"quote\"") == "a &quot;quote&quot;")
        #expect(BlueskyEmbed.escapeHTML("a & b") == "a &amp; b")
    }

    @Test func formatCount() {
        #expect(BlueskyEmbed.formatCount(0)       == "0")
        #expect(BlueskyEmbed.formatCount(999)     == "999")
        #expect(BlueskyEmbed.formatCount(1234)    == "1.2K")
        #expect(BlueskyEmbed.formatCount(3275)    == "3.3K")
        #expect(BlueskyEmbed.formatCount(1500000) == "1.5M")
    }

    @Test func formatDate_valid() {
        #expect(BlueskyEmbed.formatDate("2026-06-04T04:34:34.364Z") == "Jun 04, 2026")
    }

    @Test func formatDate_invalid() {
        #expect(BlueskyEmbed.formatDate("not a date") == nil)
        #expect(BlueskyEmbed.formatDate("") == nil)
    }

    // MARK: - buildEmbedHTML (network-free, via injected fetchJSON)

    // Pre-serialised so it is Sendable (Data is Sendable; [String: Any] is not).
    private static let samplePostData: Data = jsonBytes([
        "posts": [[
            "author": [
                "handle": "stirpicus.bsky.social",
                "displayName": "eric stirpe",
            ],
            "record": [
                "text": "This is a test post.",
                "createdAt": "2026-06-04T04:34:34.364Z",
            ],
            "likeCount": 3275,
            "repostCount": 868,
            "replyCount": 20,
            "embed": [
                "$type": "app.bsky.embed.images#view",
                "images": [["fullsize": "https://cdn.bsky.app/img/1.jpg"]],
            ],
        ]]
    ])

    @Test func buildEmbedHTML_full() async {
        let result = await BlueskyEmbed.buildEmbedHTML(
            for: "https://bsky.app/profile/stirpicus.bsky.social/post/3mngsbu7t2s27",
            fetchJSON: makeFetch(postData: Self.samplePostData)
        )
        #expect(result != nil)
        #expect(result!.contains("<blockquote"))
        #expect(result!.contains("eric stirpe"))
        #expect(result!.contains("@stirpicus.bsky.social"))
        #expect(result!.contains("This is a test post."))
        #expect(result!.contains(String(localized: "View on Bluesky")))   // locale-independent
        #expect(result!.contains("https://bsky.app/profile/stirpicus.bsky.social/post/3mngsbu7t2s27"))
        #expect(result!.contains("https://cdn.bsky.app/img/1.jpg"))
        #expect(result!.contains("3.3K"))    // likes (3275)
        #expect(result!.contains("868"))     // reposts
        #expect(result!.contains("Jun 04, 2026"))
    }

    @Test func buildEmbedHTML_noImages() async {
        let postData = jsonBytes(["posts": [[
            "author": ["handle": "user.bsky.social", "displayName": ""],
            "record": ["text": "Text only post.", "createdAt": ""],
            "likeCount": 0, "repostCount": 0, "replyCount": 0,
            "embed": [:] as [String: Any],
        ]]])
        let result = await BlueskyEmbed.buildEmbedHTML(
            for: "https://bsky.app/profile/user.bsky.social/post/abc",
            fetchJSON: makeFetch(postData: postData)
        )
        #expect(result != nil)
        #expect(result!.contains("Text only post."))
        #expect(!result!.contains("<img"))
    }

    @Test func buildEmbedHTML_stripsTrackingParams() async {
        let result = await BlueskyEmbed.buildEmbedHTML(
            for: "https://bsky.app/profile/stirpicus.bsky.social/post/3mngsbu7t2s27?foo=bar",
            fetchJSON: makeFetch(postData: Self.samplePostData)
        )
        #expect(result != nil)
        #expect(!result!.contains("?foo=bar"))
        #expect(result!.contains("https://bsky.app/profile/stirpicus.bsky.social/post/3mngsbu7t2s27"))
    }

    @Test func buildEmbedHTML_escapesHTML() async {
        let postData = jsonBytes(["posts": [[
            "author": ["handle": "user.bsky.social", "displayName": "User <bad>"],
            "record": ["text": "Test <script>alert('xss')</script> & more", "createdAt": ""],
            "likeCount": 0, "repostCount": 0, "replyCount": 0,
            "embed": [:] as [String: Any],
        ]]])
        let result = await BlueskyEmbed.buildEmbedHTML(
            for: "https://bsky.app/profile/user.bsky.social/post/abc",
            fetchJSON: makeFetch(postData: postData)
        )
        #expect(result != nil)
        #expect(!result!.contains("<script>"))
        #expect(result!.contains("&lt;script&gt;"))
        #expect(result!.contains("&amp; more"))
    }

    @Test func buildEmbedHTML_invalidURL() async {
        let result = await BlueskyEmbed.buildEmbedHTML(
            for: "https://example.com/not-a-post",
            fetchJSON: makeFetch(postData: Self.samplePostData)
        )
        #expect(result == nil)
    }

    @Test func buildEmbedHTML_apiFailure() async {
        let result = await BlueskyEmbed.buildEmbedHTML(
            for: "https://bsky.app/profile/user.bsky.social/post/abc",
            fetchJSON: { _ in throw URLError(.badServerResponse) }
        )
        #expect(result == nil)
    }

    @Test func buildEmbedHTML_didAlreadyResolved() async {
        // When actor is a DID, resolveHandle should not be called; only getPosts is called.
        nonisolated(unsafe) var resolveCallCount = 0
        let postData = Self.samplePostData
        let result = await BlueskyEmbed.buildEmbedHTML(
            for: "https://bsky.app/profile/did:plc:direct/post/abc",
            fetchJSON: { req in
                if req.url?.path.contains("resolveHandle") == true {
                    resolveCallCount += 1
                    return jsonBytes(["did": "did:plc:direct"])
                }
                return postData
            }
        )
        #expect(resolveCallCount == 0)
        #expect(result != nil)
    }
}

// MARK: - MeinMmoAggregator integration (figure strategy chain, network-free)

@Suite("MeinMmoAggregator+Bluesky")
@MainActor
struct MeinMmoAggregatorBlueskyTests {
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

    // MARK: Stub

    /// Stubs both page fetching AND Bluesky network calls so no live traffic.
    final class BlueskyStubMmo: MeinMmoAggregator, @unchecked Sendable {
        let html: String
        let bskyFetch: @Sendable (URLRequest) async throws -> Data

        init(html: String,
             bskyFetch: @escaping @Sendable (URLRequest) async throws -> Data,
             store: ImageStore) {
            self.html = html
            self.bskyFetch = bskyFetch
            super.init(
                config: FeedConfig(type: .meinMmo, identifier: "https://mein-mmo.de/feed/",
                                   dailyLimit: 20, options: .meinMmo(MeinMmoOptions()), collectedToday: 0),
                credentials: .init(), store: store
            )
        }

        override func fetchEntries() async throws -> [FeedEntry] { [] }
        override func fetchArticleHTML(_ url: String) async throws -> String { html }
        override func fetchAdditionalPage(_ url: String) async throws -> String { "" }
        override func fetchJSONForBluesky(_ request: URLRequest) async throws -> Data {
            try await bskyFetch(request)
        }
    }

    private static let samplePostData: Data = jsonBytes([
        "posts": [[
            "author": ["handle": "user.bsky.social", "displayName": "Test User"],
            "record": ["text": "Hello from Bluesky!", "createdAt": "2026-06-04T04:34:34.364Z"],
            "likeCount": 10, "repostCount": 2, "replyCount": 1,
            "embed": [:] as [String: Any],
        ]]
    ])

    private func makeOkFetch() -> @Sendable (URLRequest) async throws -> Data {
        let postData = Self.samplePostData
        return { req in
            if req.url?.path.contains("resolveHandle") == true {
                return jsonBytes(["did": "did:plc:test"])
            }
            return postData
        }
    }

    @Test func blueskyFigureIsReplacedWithEmbed() async throws {
        let articleHTML = """
        <html><body><div class="entry-content">
          <p>Some article text.</p>
          <figure class="wp-block-embed">
            <a href="https://bsky.app/profile/user.bsky.social/post/abc123">Bluesky post</a>
          </figure>
        </div></body></html>
        """
        let agg = BlueskyStubMmo(html: articleHTML, bskyFetch: makeOkFetch(), store: tempStore())
        let base = agg.makeArticle(from: entry())
        let result = try await agg.enrich(base, entry: entry())

        #expect(result.content.contains("Hello from Bluesky!"))
        #expect(result.content.contains(String(localized: "View on Bluesky")))   // locale-independent
        #expect(result.content.contains("bluesky-embed"))
        #expect(!result.content.contains("<figure"))
    }

    @Test func blueskyFigureLeftUnchangedOnAPIFailure() async throws {
        let articleHTML = """
        <html><body><div class="entry-content">
          <figure class="wp-block-embed">
            <a href="https://bsky.app/profile/user.bsky.social/post/abc123">Bluesky post</a>
          </figure>
        </div></body></html>
        """
        let agg = BlueskyStubMmo(
            html: articleHTML,
            bskyFetch: { _ in throw URLError(.badServerResponse) },
            store: tempStore()
        )
        let base = agg.makeArticle(from: entry())
        let result = try await agg.enrich(base, entry: entry())

        // On failure, figure is left unchanged (graceful fallback).
        #expect(result.content.contains("bsky.app"))
    }
}
