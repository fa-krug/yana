# Phase 4e — Social / Media Aggregators (Reddit, YouTube, Podcast) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the server's three API/media aggregators to on-device Swift — **Reddit** (raw application-only OAuth replacing PRAW), **YouTube** (Data API v3), and **Podcast** (RSS subclass) — each fixture-tested with no live network, then wire them into the registry and add live-search pickers to the feed editor.

**Architecture:** Reddit and YouTube conform to the `Aggregator` protocol **directly** (they are API-based, not RSS pipelines). Each gets a small raw API client (`RedditClient`, `YouTubeClient`) that takes an **injectable fetch closure** (`@Sendable (URLRequest) async throws -> Data`, defaulting to `HTTPClient.fetchJSON`) so tests inject canned JSON. The aggregators reproduce the server's exact article HTML shape via the 4b utilities (`ContentFormatter`, `EmbedRewriter`, `ImageStore`, `rewriteImages`). Podcast subclasses `RSSPipelineAggregator` (4c) and overrides `parseToRawArticles`-equivalent hooks to build the artwork/audio-player/show-notes markup. A minimal **Reddit-markdown→HTML converter** ports the server's `markdown.py` (paragraphs, links, bold/italic, strikethrough, superscript, spoilers, blockquotes, lists, auto-linkify) without a markdown library.

**Tech Stack:** Swift 6 (strict concurrency), SwiftSoup, SwiftData, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-16-local-aggregator-phase4-design.md` (§4.3).

**Depends on:**
- **4a** — `FeedConfig`, `Aggregator` protocol (`validate()` + async `aggregate()`), `AggregatorCredentials` (`redditClientID` / `redditClientSecret` / `youtubeAPIKey`), `AggregatorError` (`.missingAPIKey(AggregatorAPIKey)`, `.missingIdentifier`, `.articleSkip(statusCode:)`, `.contentFetch`, `.parse`), `AggregatorRegistry.makeAggregator`.
- **4b** — `HTTPClient.fetchJSON(_:)` / `fetchData(_:)`, `FeedParser` / `FeedEntry`, `ContentFormatter.format` / `headerImageHTML`, `EmbedRewriter.youTubeEmbedHTML(videoID:)` / `extractYouTubeID(from:)`, `ImageStore`, `rewriteImages`, `ReaderWeb.imageScheme`, `HTMLUtils`.
- **4c** — `RSSPipelineAggregator` base class + hooks (Podcast subclasses it).

**Server reference:** `/Users/skrug/PycharmProjects/Yana/core/aggregators/{reddit,youtube,podcast}/`.

---

## Locked contracts (referenced across tasks)

The two API clients expose an injectable fetch closure so every test runs hermetically:

```swift
// Reddit
struct RedditTokenResponse: Decodable { let access_token: String }

final class RedditClient: @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data
    init(clientID: String, clientSecret: String, userAgent: String, fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) })

    func authToken() async throws -> String                                   // app-only OAuth, cached per instance
    func fetchListing(subreddit: String, sort: String, limit: Int) async throws -> [RedditPostData]
    func fetchComments(subreddit: String, postID: String) async throws -> [RedditComment]
    static func searchSubreddits(query: String, credentials: AggregatorCredentials,
                                 userAgent: String, fetch: Fetch = { try await HTTPClient.fetchJSON($0) }) async -> [RedditSubredditResult]
}

// YouTube
final class YouTubeClient: @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data
    init(apiKey: String, fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) })

    func resolveChannelID(_ identifier: String) async throws -> String
    func fetchChannelData(_ channelID: String) async throws -> YouTubeChannelData   // uploads playlist + title
    func fetchVideos(playlistID: String, max: Int) async throws -> [YouTubeVideo]
    func fetchVideoComments(videoID: String, max: Int) async throws -> [YouTubeComment]
    static func searchChannels(query: String, apiKey: String,
                               fetch: Fetch = { try await HTTPClient.fetchJSON($0) }) async -> [YouTubeChannelResult]
}
```

Test/build command (single suite):

```
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/<Suite>
```

Full suite:

```
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

---

## File Structure

- Create `Yana/Aggregators/Concrete/RedditMarkdown.swift` — Reddit-markdown→HTML converter.
- Create `Yana/Aggregators/Concrete/RedditClient.swift` — OAuth + listing/comments/search, injectable fetch.
- Create `Yana/Aggregators/Concrete/RedditModels.swift` — `RedditPostData`, `RedditComment`, `RedditSubredditResult` (Codable DTOs).
- Create `Yana/Aggregators/Concrete/RedditAggregator.swift` — conforms to `Aggregator` directly.
- Create `Yana/Aggregators/Concrete/YouTubeClient.swift` — Data API v3, injectable fetch.
- Create `Yana/Aggregators/Concrete/YouTubeModels.swift` — `YouTubeVideo`, `YouTubeComment`, `YouTubeChannelData`, `YouTubeChannelResult`.
- Create `Yana/Aggregators/Concrete/YouTubeAggregator.swift` — conforms to `Aggregator` directly.
- Create `Yana/Aggregators/Concrete/PodcastAggregator.swift` — `class PodcastAggregator: RSSPipelineAggregator`.
- Modify `Yana/Aggregators/AggregatorRegistry.swift` — add reddit/youtube/podcast cases.
- Modify `Yana/Views/Config/FeedEditorView.swift` + create `Yana/Views/Config/IdentifierSearchView.swift` — live-search picker.
- Tests: `RedditMarkdownTests`, `RedditClientTests`, `RedditAggregatorTests`, `YouTubeClientTests`, `YouTubeAggregatorTests`, `PodcastAggregatorTests`, `AggregatorRegistrySocialTests`.

---

## Task 1: `RedditMarkdown` — Reddit-markdown → HTML

Ports `reddit/markdown.py`: preview-image substitution, superscript `^x` / `^(x)`, strikethrough `~~x~~`, spoilers `>!x!<`, then standard markdown (paragraphs, `[t](u)` links, `**bold**`/`*italic*`, `>` blockquotes, `-`/`*`/`1.` lists), then auto-linkify bare URLs and force `target="_blank" rel="noopener"` on every link.

**Files:**
- Create: `Yana/Aggregators/Concrete/RedditMarkdown.swift`
- Test: `YanaTests/RedditMarkdownTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/RedditMarkdownTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("RedditMarkdown")
struct RedditMarkdownTests {
    @Test func emptyInputReturnsEmpty() {
        #expect(RedditMarkdown.toHTML("") == "")
    }

    @Test func paragraphsBecomeParagraphTags() {
        let html = RedditMarkdown.toHTML("First line.\n\nSecond line.")
        #expect(html.contains("<p>First line.</p>"))
        #expect(html.contains("<p>Second line.</p>"))
    }

    @Test func markdownLinkBecomesAnchorOpeningNewTab() {
        let html = RedditMarkdown.toHTML("See [the docs](https://example.com/x).")
        #expect(html.contains("href=\"https://example.com/x\""))
        #expect(html.contains(">the docs</a>"))
        #expect(html.contains("target=\"_blank\""))
        #expect(html.contains("rel=\"noopener\""))
    }

    @Test func boldAndItalicConvert() {
        let html = RedditMarkdown.toHTML("This is **bold** and *italic*.")
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
    }

    @Test func strikethroughAndSpoilerAndSuperscript() {
        #expect(RedditMarkdown.toHTML("~~gone~~").contains("<del>gone</del>"))
        #expect(RedditMarkdown.toHTML(">!secret!<").contains("class=\"spoiler\""))
        #expect(RedditMarkdown.toHTML("E=mc^2").contains("<sup>2</sup>"))
        #expect(RedditMarkdown.toHTML("foot^(note here)").contains("<sup>note here</sup>"))
    }

    @Test func blockquoteAndUnorderedList() {
        let quote = RedditMarkdown.toHTML("> quoted text")
        #expect(quote.contains("<blockquote>"))
        #expect(quote.contains("quoted text"))
        let list = RedditMarkdown.toHTML("- one\n- two")
        #expect(list.contains("<ul>"))
        #expect(list.contains("<li>one</li>"))
        #expect(list.contains("<li>two</li>"))
    }

    @Test func bareURLGetsLinkified() {
        let html = RedditMarkdown.toHTML("visit https://example.com now")
        #expect(html.contains("<a href=\"https://example.com\""))
        #expect(html.contains("target=\"_blank\""))
    }

    @Test func previewReddItBecomesImage() {
        let html = RedditMarkdown.toHTML("https://preview.redd.it/abc.png?width=100")
        #expect(html.contains("<img"))
        #expect(html.contains("preview.redd.it/abc.png"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditMarkdownTests`
Expected: FAIL — `cannot find 'RedditMarkdown' in scope`.

- [ ] **Step 3: Implement `RedditMarkdown`**

Create `Yana/Aggregators/Concrete/RedditMarkdown.swift`:

```swift
import Foundation

/// Minimal Reddit-markdown → HTML converter porting `reddit/markdown.py`.
/// Handles Reddit extensions (superscript, strikethrough, spoilers, preview images),
/// a pragmatic markdown subset (paragraphs, links, bold/italic, blockquotes, lists),
/// then auto-linkifies bare URLs and forces links to open in a new tab.
enum RedditMarkdown {
    static func toHTML(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var t = String(text.prefix(100_000))     // DoS guard (server: 100KB)

        t = replacePreviewImages(t)
        t = applyInline(t)                        // superscript / strikethrough / spoiler
        let html = blocksToHTML(t)                // paragraphs / lists / blockquotes / inline emphasis+links
        return linkifyAndTarget(html)
    }

    // MARK: - Reddit preview images

    private static func replacePreviewImages(_ text: String) -> String {
        var t = text
        // markdown link to preview image -> <img>
        t = regexReplace(t, #"\[([^\]]{0,200})\]\((https?://preview\.redd\.it/[^\s)]{1,500})\)"#) { groups in
            let alt = groups[1].isEmpty ? "Reddit preview image" : escape(groups[1])
            return "<img src=\"\(decodeEntities(groups[2]))\" alt=\"\(alt)\">"
        }
        // bare preview image url -> <img> (not already inside a markdown link)
        t = regexReplace(t, #"(?<!\]\()https?://preview\.redd\.it/[^\s)]+"#) { groups in
            "<img src=\"\(decodeEntities(groups[0]))\" alt=\"Reddit preview image\">"
        }
        return t
    }

    // MARK: - Reddit inline extensions (applied to raw text, pre-block)

    private static func applyInline(_ text: String) -> String {
        var t = text
        t = regexReplace(t, #"\^\(([^)]+)\)"#) { "<sup>\($0[1])</sup>" }
        t = regexReplace(t, #"\^(\w+)"#) { "<sup>\($0[1])</sup>" }
        t = regexReplace(t, #"~~(.+?)~~"#) { "<del>\($0[1])</del>" }
        t = regexReplace(t, #">!(.+?)!<"#) {
            "<span class=\"spoiler\" style=\"background: #000; color: #000;\">\($0[1])</span>"
        }
        return t
    }

    // MARK: - Block-level markdown

    private static func blocksToHTML(_ text: String) -> String {
        // Split into blank-line-delimited blocks.
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            if lines.allSatisfy({ $0.hasPrefix("> ") || $0 == ">" }) {
                let inner = lines.map { line in
                    emphasisAndLinks(String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1)))
                }.joined(separator: "<br>")
                out.append("<blockquote><p>\(inner)</p></blockquote>")
            } else if lines.allSatisfy({ isUnorderedItem($0) }) {
                let items = lines.map { "<li>\(emphasisAndLinks(stripBullet($0)))</li>" }.joined()
                out.append("<ul>\(items)</ul>")
            } else if lines.allSatisfy({ isOrderedItem($0) }) {
                let items = lines.map { "<li>\(emphasisAndLinks(stripNumber($0)))</li>" }.joined()
                out.append("<ol>\(items)</ol>")
            } else {
                // Paragraph: single newlines become <br> (nl2br parity).
                let joined = lines.map { emphasisAndLinks($0) }.joined(separator: "<br>")
                out.append("<p>\(joined)</p>")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func isUnorderedItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }
    private static func stripBullet(_ line: String) -> String { String(line.dropFirst(2)) }
    private static func isOrderedItem(_ line: String) -> Bool {
        line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }
    private static func stripNumber(_ line: String) -> String {
        regexReplace(line, #"^\d+\.\s"#) { _ in "" }
    }

    // MARK: - Inline emphasis + markdown links (within a line)

    private static func emphasisAndLinks(_ line: String) -> String {
        var s = line
        s = regexReplace(s, #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#) { g in
            "<a href=\"\(decodeEntities(g[2]))\">\(g[1])</a>"
        }
        s = regexReplace(s, #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        s = regexReplace(s, #"\*(.+?)\*"#) { "<em>\($0[1])</em>" }
        s = regexReplace(s, #"`([^`]+)`"#) { "<code>\($0[1])</code>" }
        return s
    }

    // MARK: - Linkify bare URLs + force target/rel on every anchor

    private static func linkifyAndTarget(_ html: String) -> String {
        // Linkify bare URLs that are not already inside an href/anchor.
        var out = regexReplace(html, #"(?<!["'=>])(https?://[^\s<"]+)"#) { g in
            let raw = g[1]
            let clean = raw.replacingOccurrences(of: #"[.,;:!?)]+$"#, with: "", options: .regularExpression)
            let trailing = String(raw.dropFirst(clean.count))
            return "<a href=\"\(clean)\">\(clean)</a>\(trailing)"
        }
        // Force target/rel on every anchor (idempotent).
        out = regexReplace(out, #"<a (?![^>]*target=)"#) { _ in "<a target=\"_blank\" rel=\"noopener\" " }
        return out
    }

    // MARK: - Helpers

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decodeEntities(_ s: String) -> String {
        var d = s.replacingOccurrences(of: "&amp;", with: "&")
        if d.contains("&") { d = d.replacingOccurrences(of: "&amp;", with: "&") }
        return d
    }

    /// Regex replace with a closure receiving capture groups (group 0 = whole match).
    private static func regexReplace(_ input: String, _ pattern: String,
                                     _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        for match in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditMarkdownTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditMarkdown.swift YanaTests/RedditMarkdownTests.swift
git commit -m "feat: Reddit-markdown to HTML converter"
```

---

## Task 2: `RedditClient` — app-only OAuth + listing/comments (injectable fetch)

Ports `reddit/auth.py` (replacing PRAW with raw OAuth) + `reddit/comments.py` fetch/filter/sort. The client requests a bearer token via `POST https://www.reddit.com/api/v1/access_token` (grant `client_credentials`, HTTP Basic `clientID:clientSecret`, `User-Agent` header), then GETs `https://oauth.reddit.com/r/{sub}/{sort}.json?limit=N&raw_json=1` and `https://oauth.reddit.com/comments/{id}.json?sort=best&raw_json=1` with the bearer. Comments are filtered (bot/deleted), sorted by score desc, capped at the limit.

**Files:**
- Create: `Yana/Aggregators/Concrete/RedditModels.swift`
- Create: `Yana/Aggregators/Concrete/RedditClient.swift`
- Test: `YanaTests/RedditClientTests.swift`

- [ ] **Step 1: Write the failing test (injected canned JSON — no network)**

Create `YanaTests/RedditClientTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("RedditClient")
struct RedditClientTests {
    private let tokenJSON = #"{"access_token":"TKN","token_type":"bearer","expires_in":3600}"#

    private let listingJSON = """
    {"data":{"children":[
      {"data":{"id":"p1","title":"Hello","selftext":"Body **bold**","url":"https://reddit.com/r/swift/comments/p1/hello/",
               "permalink":"/r/swift/comments/p1/hello/","created_utc":1700000000,"author":"alice",
               "score":42,"num_comments":7,"is_self":true,"is_gallery":false,"is_video":false}},
      {"data":{"id":"am","title":"Pinned","selftext":"","url":"","permalink":"/r/swift/comments/am/pinned/",
               "created_utc":1700000000,"author":"AutoModerator","score":1,"num_comments":0,"is_self":true}}
    ]}}
    """

    private let commentsJSON = """
    [
      {"data":{"children":[{"data":{"id":"px","title":"Hello","selftext":"x","permalink":"/r/swift/comments/p1/hello/","author":"alice","created_utc":1700000000,"num_comments":7}}]}},
      {"data":{"children":[
        {"kind":"t1","data":{"id":"c1","body":"Top comment","author":"bob","score":10,"permalink":"/r/swift/comments/p1/hello/c1/"}},
        {"kind":"t1","data":{"id":"c2","body":"Low comment","author":"carol","score":2,"permalink":"/r/swift/comments/p1/hello/c2/"}},
        {"kind":"t1","data":{"id":"c3","body":"[deleted]","author":"dave","score":99,"permalink":"/x"}},
        {"kind":"t1","data":{"id":"c4","body":"bot output","author":"helpful_bot","score":50,"permalink":"/y"}},
        {"kind":"more","data":{"id":"more"}}
      ]}}
    ]
    """

    /// Routes by URL so one client serves token, listing, and comments.
    private func client() -> RedditClient {
        RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(self.commentsJSON.utf8) }
            return Data(self.listingJSON.utf8)
        }
    }

    @Test func authTokenIsParsed() async throws {
        let token = try await client().authToken()
        #expect(token == "TKN")
    }

    @Test func listingParsesPosts() async throws {
        let posts = try await client().fetchListing(subreddit: "swift", sort: "hot", limit: 25)
        #expect(posts.count == 2)
        #expect(posts.first?.title == "Hello")
        #expect(posts.first?.author == "alice")
        #expect(posts.first?.numComments == 7)
    }

    @Test func commentsFilteredSortedAndCapped() async throws {
        let comments = try await client().fetchComments(subreddit: "swift", postID: "p1")
        // deleted + bot removed; sorted by score desc.
        #expect(comments.map(\.author) == ["bob", "carol"])
        #expect(comments.first?.score == 10)
    }

    @Test func authRequestUsesBasicAuthAndUserAgent() async throws {
        var captured: URLRequest?
        let c = RedditClient(clientID: "abc", clientSecret: "xyz", userAgent: "MyAgent/9") { request in
            if request.url!.absoluteString.contains("access_token") { captured = request }
            return Data(self.tokenJSON.utf8)
        }
        _ = try await c.authToken()
        let req = try #require(captured)
        let basic = Data("abc:xyz".utf8).base64EncodedString()
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Basic \(basic)")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "MyAgent/9")
        #expect(req.httpMethod == "POST")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditClientTests`
Expected: FAIL — `cannot find 'RedditClient' in scope`.

- [ ] **Step 3: Implement the models**

Create `Yana/Aggregators/Concrete/RedditModels.swift`:

```swift
import Foundation

/// Subset of a Reddit post (`/r/{sub}/{sort}.json` child `data`) needed for aggregation.
struct RedditPostData: Decodable, Sendable {
    var id: String
    var title: String
    var selftext: String
    var url: String
    var permalink: String
    var createdUTC: Double
    var author: String
    var score: Int
    var numComments: Int
    var thumbnail: String?
    var isSelf: Bool
    var isGallery: Bool
    var isVideo: Bool
    var preview: Preview?
    var mediaMetadata: [String: MediaMeta]?
    var galleryData: GalleryData?
    var crosspostParentList: [RedditPostData]?

    struct Preview: Decodable, Sendable {
        var images: [PreviewImage]
        struct PreviewImage: Decodable, Sendable {
            var source: Source?
            struct Source: Decodable, Sendable { var url: String? }
        }
    }
    struct MediaMeta: Decodable, Sendable {
        var e: String?               // "Image" | "AnimatedImage"
        var s: MediaSource?
        struct MediaSource: Decodable, Sendable { var u: String?; var gif: String?; var mp4: String? }
    }
    struct GalleryData: Decodable, Sendable {
        var items: [Item]
        struct Item: Decodable, Sendable { var mediaID: String?; var caption: String? }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, selftext, url, permalink, author, score, thumbnail, preview
        case createdUTC = "created_utc"
        case numComments = "num_comments"
        case isSelf = "is_self"
        case isGallery = "is_gallery"
        case isVideo = "is_video"
        case mediaMetadata = "media_metadata"
        case galleryData = "gallery_data"
        case crosspostParentList = "crosspost_parent_list"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        selftext = (try? c.decode(String.self, forKey: .selftext)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        permalink = (try? c.decode(String.self, forKey: .permalink)) ?? ""
        createdUTC = (try? c.decode(Double.self, forKey: .createdUTC)) ?? 0
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        score = (try? c.decode(Int.self, forKey: .score)) ?? 0
        numComments = (try? c.decode(Int.self, forKey: .numComments)) ?? 0
        thumbnail = try? c.decode(String.self, forKey: .thumbnail)
        isSelf = (try? c.decode(Bool.self, forKey: .isSelf)) ?? false
        isGallery = (try? c.decode(Bool.self, forKey: .isGallery)) ?? false
        isVideo = (try? c.decode(Bool.self, forKey: .isVideo)) ?? false
        preview = try? c.decode(Preview.self, forKey: .preview)
        mediaMetadata = try? c.decode([String: MediaMeta].self, forKey: .mediaMetadata)
        galleryData = try? c.decode(GalleryData.self, forKey: .galleryData)
        crosspostParentList = try? c.decode([RedditPostData].self, forKey: .crosspostParentList)
    }
}

struct RedditComment: Decodable, Sendable {
    var id: String
    var body: String
    var author: String
    var score: Int
    var permalink: String
    enum CodingKeys: String, CodingKey { case id, body, author, score, permalink }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        score = (try? c.decode(Int.self, forKey: .score)) ?? 0
        permalink = (try? c.decode(String.self, forKey: .permalink)) ?? ""
    }
}

/// Live-search result for the editor picker.
struct RedditSubredditResult: Sendable, Identifiable {
    var displayName: String      // value saved as the feed identifier
    var title: String
    var subscribers: Int
    var id: String { displayName }
}
```

- [ ] **Step 4: Implement `RedditClient`**

Create `Yana/Aggregators/Concrete/RedditClient.swift`:

```swift
import Foundation

/// Raw Reddit application-only OAuth client (replaces PRAW). Injectable fetch closure
/// keeps tests hermetic. `@unchecked Sendable`: created per run, the cached token is the
/// only mutable state and it is set once before concurrent reads.
final class RedditClient: @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    private let clientID: String
    private let clientSecret: String
    private let userAgent: String
    private let fetch: Fetch
    private var cachedToken: String?

    init(clientID: String, clientSecret: String, userAgent: String,
         fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.userAgent = userAgent
        self.fetch = fetch
    }

    func authToken() async throws -> String {
        if let cachedToken { return cachedToken }
        var req = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        req.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        let data = try await fetch(req)
        let token = (try? JSONDecoder().decode(RedditTokenResponse.self, from: data))?.access_token
        guard let token, !token.isEmpty else { throw AggregatorError.contentFetch("Reddit auth failed") }
        cachedToken = token
        return token
    }

    func fetchListing(subreddit: String, sort: String, limit: Int) async throws -> [RedditPostData] {
        let url = URL(string: "https://oauth.reddit.com/r/\(subreddit)/\(sort).json?limit=\(limit)&raw_json=1")!
        let data = try await authorizedGET(url)
        let listing = try JSONDecoder().decode(RedditListing.self, from: data)
        return listing.data.children.map(\.data)
    }

    func fetchComments(subreddit: String, postID: String) async throws -> [RedditComment] {
        let url = URL(string: "https://oauth.reddit.com/comments/\(postID).json?sort=best&raw_json=1")!
        let data = try await authorizedGET(url)
        // Response is [postListing, commentListing]; index 1 holds the comments.
        let listings = try JSONDecoder().decode([RedditCommentEnvelope].self, from: data)
        guard listings.count >= 2 else { return [] }
        let raw = listings[1].data.children.compactMap(\.data)        // skips "more" kind (no data fields)
        let valid = raw.filter { isValidComment($0) }
        return valid.sorted { $0.score > $1.score }
    }

    static func searchSubreddits(query: String, credentials: AggregatorCredentials,
                                 userAgent: String,
                                 fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) async -> [RedditSubredditResult] {
        guard let id = credentials.redditClientID, let secret = credentials.redditClientSecret,
              !query.isEmpty else { return [] }
        let client = RedditClient(clientID: id, clientSecret: secret, userAgent: userAgent, fetch: fetch)
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://oauth.reddit.com/subreddits/search.json?q=\(q)&limit=10&raw_json=1"),
              let data = try? await client.authorizedGET(url),
              let listing = try? JSONDecoder().decode(RedditSubredditListing.self, from: data) else { return [] }
        return listing.data.children.map {
            RedditSubredditResult(displayName: $0.data.displayName ?? "",
                                  title: $0.data.title ?? "",
                                  subscribers: $0.data.subscribers ?? 0)
        }.filter { !$0.displayName.isEmpty }
    }

    // MARK: - Helpers

    private func authorizedGET(_ url: URL) async throws -> Data {
        let token = try await authToken()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await fetch(req)
    }

    private func isValidComment(_ c: RedditComment) -> Bool {
        guard !c.body.isEmpty, c.body != "[deleted]", c.body != "[removed]", !c.author.isEmpty else { return false }
        let a = c.author.lowercased()
        return !(a.hasSuffix("_bot") || a.hasSuffix("-bot") || a == "automoderator")
    }
}

struct RedditTokenResponse: Decodable { let access_token: String }

// MARK: - Decoding envelopes

private struct RedditListing: Decodable {
    let data: ListingData
    struct ListingData: Decodable { let children: [Child] }
    struct Child: Decodable { let data: RedditPostData }
}
private struct RedditCommentEnvelope: Decodable {
    let data: ListingData
    struct ListingData: Decodable { let children: [Child] }
    struct Child: Decodable {
        let data: RedditComment?     // optional: "more" kind has no comment fields
    }
}
private struct RedditSubredditListing: Decodable {
    let data: ListingData
    struct ListingData: Decodable { let children: [Child] }
    struct Child: Decodable { let data: SubData }
    struct SubData: Decodable {
        let displayName: String?
        let title: String?
        let subscribers: Int?
        enum CodingKeys: String, CodingKey {
            case displayName = "display_name", title, subscribers
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditClientTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditModels.swift Yana/Aggregators/Concrete/RedditClient.swift YanaTests/RedditClientTests.swift
git commit -m "feat: Reddit OAuth client (token, listing, comments, search)"
```

---

## Task 3: `RedditAggregator` — conforms to `Aggregator` directly

Ports `reddit/aggregator.py` + `reddit/content.py` + `reddit/images.py`. Pipeline: normalize subreddit → fetch listing (3x over-fetch, capped 100) → drop AutoModerator / age (`minAgeHours`) / `< minComments` → for each post build content (selftext markdown, gallery, link media, comments blockquotes) → strip the header image from the body → fetch+cache the header image via `ImageStore` (when `includeHeaderImage`) → wrap with `ContentFormatter.format`. Throws `.missingAPIKey(.reddit)` when client id/secret absent.

**Files:**
- Create: `Yana/Aggregators/Concrete/RedditAggregator.swift`
- Test: `YanaTests/RedditAggregatorTests.swift`

- [ ] **Step 1: Write the failing test (injected RedditClient + ImageStore — no network)**

Create `YanaTests/RedditAggregatorTests.swift`:

```swift
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
    private let listingJSON = """
    {"data":{"children":[
      {"data":{"id":"p1","title":"Hello","selftext":"Body **bold** [docs](https://e.com/d)",
               "url":"https://i.redd.it/pic.png","permalink":"/r/swift/comments/p1/hello/",
               "created_utc":1700000000,"author":"alice","score":42,"num_comments":7,"is_self":false}},
      {"data":{"id":"am","title":"Pinned","selftext":"","url":"","permalink":"/r/swift/comments/am/p/",
               "created_utc":1700000000,"author":"AutoModerator","score":1,"num_comments":99,"is_self":true}},
      {"data":{"id":"lc","title":"Few comments","selftext":"x","url":"","permalink":"/r/swift/comments/lc/p/",
               "created_utc":1700000000,"author":"carol","score":1,"num_comments":1,"is_self":true}}
    ]}}
    """
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
        #expect(a.content.contains("Source:"))                    // formatArticleContent footer
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditAggregatorTests`
Expected: FAIL — `cannot find 'RedditAggregator' in scope`.

- [ ] **Step 3: Implement `RedditAggregator`**

Create `Yana/Aggregators/Concrete/RedditAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Reddit aggregator (application-only OAuth). Conforms to `Aggregator` directly (API-based,
/// not an RSS pipeline). Reproduces the server's post content + comments + header-image shape.
final class RedditAggregator: Aggregator, @unchecked Sendable {
    private let config: FeedConfig
    private let credentials: AggregatorCredentials
    private let store: ImageStore
    private let injectedClient: RedditClient?

    init(config: FeedConfig, credentials: AggregatorCredentials, store: ImageStore = .shared,
         client: RedditClient? = nil) {
        self.config = config
        self.credentials = credentials
        self.store = store
        self.injectedClient = client
    }

    private var options: RedditOptions {
        if case .reddit(let o) = config.options { return o }
        return RedditOptions()
    }

    func validate() throws {
        guard !normalizedSubreddit.isEmpty else { throw AggregatorError.missingIdentifier }
        guard credentials.redditClientID != nil, credentials.redditClientSecret != nil else {
            throw AggregatorError.missingAPIKey(.reddit)
        }
    }

    func aggregate() async throws -> [AggregatedArticle] {
        try validate()
        let client = try makeClient()
        let opts = options
        let limit = max(config.dailyLimit, 1)
        let fetchLimit = min(limit * 3, 100)

        let posts = try await client.fetchListing(subreddit: normalizedSubreddit, sort: opts.subredditSort, limit: fetchLimit)
        let cutoff = Date().addingTimeInterval(-Double(opts.minAgeHours) * 3600)
        let twoMonths = Date().addingTimeInterval(-60 * 24 * 3600)

        var result: [AggregatedArticle] = []
        for post in posts {
            let original = post.crosspostParentList?.first ?? post
            let date = Date(timeIntervalSince1970: original.createdUTC)
            if date < twoMonths { continue }
            if opts.minAgeHours > 0 && date > cutoff { continue }
            if post.author == "AutoModerator" { continue }
            if opts.minComments > 0 && post.numComments < opts.minComments { continue }
            if result.count >= limit { break }

            let permalink = "https://reddit.com\(RedditMarkdown.decodeEntities(original.permalink))"
            let isCrossPost = post.crosspostParentList?.isEmpty == false
            var body = try await buildContent(post: original, isCrossPost: isCrossPost, client: client)
            let headerURL = headerImageURL(for: original)

            if let headerURL { body = stripImage(from: body, url: headerURL) }
            var headerHTML: String?
            if opts.includeHeaderImage, let headerURL {
                headerHTML = try await makeHeaderHTML(headerURL, title: original.title)
            }
            let content = ContentFormatter.format(content: body, title: original.title, url: permalink,
                                                  headerHTML: headerHTML, commentsHTML: nil)
            result.append(AggregatedArticle(
                title: original.title, identifier: permalink, url: permalink,
                rawContent: body, content: content,
                date: date, author: post.author, iconURL: nil))
        }
        return result
    }

    // MARK: - Content building (ports reddit/content.py)

    private func buildContent(post: RedditPostData, isCrossPost: Bool, client: RedditClient) async throws -> String {
        var parts: [String] = []
        if !post.selftext.isEmpty { parts.append("<div>\(RedditMarkdown.toHTML(post.selftext))</div>") }
        addGalleryMedia(post, &parts)
        addLinkMedia(post, &parts, isCrossPost: isCrossPost)
        try await addComments(post, &parts, client: client)
        return parts.joined()
    }

    private func addGalleryMedia(_ post: RedditPostData, _ parts: inout [String]) {
        guard post.isGallery, let meta = post.mediaMetadata, let gallery = post.galleryData else { return }
        for item in gallery.items {
            guard let mid = item.mediaID, let info = meta[mid] else { continue }
            let animated = info.e == "AnimatedImage"
            let raw = animated ? (info.s?.gif ?? info.s?.mp4) : (info.e == "Image" ? info.s?.u : nil)
            guard let raw else { continue }
            let url = RedditMarkdown.decodeEntities(raw)
            let alt = item.caption.map { RedditMarkdown.escape($0) } ?? (animated ? "Animated GIF" : "Gallery image")
            if let caption = item.caption, !caption.isEmpty {
                parts.append("<figure><img src=\"\(url)\" alt=\"\(alt)\"><figcaption>\(alt)</figcaption></figure>")
            } else {
                parts.append("<p><img src=\"\(url)\" alt=\"\(alt)\"></p>")
            }
        }
    }

    private func addLinkMedia(_ post: RedditPostData, _ parts: inout [String], isCrossPost: Bool) {
        guard !post.url.isEmpty, !post.isGallery else { return }
        let url = RedditMarkdown.decodeEntities(post.url)
        let lower = url.lowercased()
        if lower.hasSuffix(".gif") || lower.hasSuffix(".gifv") {
            let gif = lower.hasSuffix(".gifv") ? String(url.dropLast()) : url
            parts.append("<p><img src=\"\(gif)\" alt=\"Animated GIF\"></p>"); return
        }
        let isImage = [".jpg", ".jpeg", ".png", ".webp"].contains { lower.contains($0) } || lower.contains("i.redd.it")
        if isImage {
            parts.append("<p><a href=\"\(url)\" target=\"_blank\" rel=\"noopener\">\(RedditMarkdown.escape(url))</a></p>"); return
        }
        if lower.contains("v.redd.it") { return }            // handled in header
        if lower.contains("youtube.com") || lower.contains("youtu.be") {
            parts.append("<p><a href=\"\(url)\" target=\"_blank\" rel=\"noopener\">▶ View Video on YouTube</a></p>"); return
        }
        if lower.contains("twitter.com") || lower.contains("x.com") { return }   // header embed
        if !isCrossPost && !post.isSelf {
            parts.append("<p><a href=\"\(url)\" target=\"_blank\" rel=\"noopener\">\(RedditMarkdown.escape(url))</a></p>")
        }
    }

    private func addComments(_ post: RedditPostData, _ parts: inout [String], client: RedditClient) async throws {
        let permalink = "https://reddit.com\(RedditMarkdown.decodeEntities(post.permalink))"
        var section = ["<h3><a href=\"\(permalink)\" target=\"_blank\" rel=\"noopener\">Comments</a></h3>"]
        let limit = options.commentLimit
        if limit > 0 {
            let comments = (try? await client.fetchComments(subreddit: normalizedSubreddit, postID: post.id)) ?? []
            if comments.isEmpty {
                section.append("<p><em>No comments yet.</em></p>")
            } else {
                section.append(comments.prefix(limit).map(commentHTML).joined())
            }
        } else {
            section.append("<p><em>Comments disabled.</em></p>")
        }
        parts.append("<section>\(section.joined())</section>")
    }

    private func commentHTML(_ comment: RedditComment) -> String {
        let author = comment.author.isEmpty ? "[deleted]" : comment.author
        let body = RedditMarkdown.toHTML(comment.body)
        let url = "https://reddit.com\(comment.permalink)"
        return """
        <blockquote>
        <p><strong>\(RedditMarkdown.escape(author))</strong> | <a href="\(url)" target="_blank" rel="noopener">source</a></p>
        <div>\(body)</div>
        </blockquote>
        """
    }

    // MARK: - Header image (ports reddit/images.py priority chain, minus link-page scraping)

    private func headerImageURL(for post: RedditPostData) -> String? {
        // YouTube videos embed via header strategy elsewhere; here we surface direct images.
        if !post.url.isEmpty, EmbedRewriter.extractYouTubeID(from: post.url) != nil {
            return RedditMarkdown.decodeEntities(post.url)
        }
        // Gallery first image
        if post.isGallery, let meta = post.mediaMetadata, let first = post.galleryData?.items.first,
           let mid = first.mediaID, let info = meta[mid] {
            if info.e == "AnimatedImage", let raw = info.s?.gif ?? info.s?.mp4 { return RedditMarkdown.decodeEntities(raw) }
            if info.e == "Image", let raw = info.s?.u { return RedditMarkdown.decodeEntities(raw) }
        }
        // Direct image post
        if !post.url.isEmpty {
            let decoded = RedditMarkdown.decodeEntities(post.url)
            let lower = decoded.lowercased()
            let isDirect = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".gifv"].contains { lower.contains($0) }
                || lower.contains("i.redd.it")
            if isDirect { return decoded }
        }
        // Preview source
        if let src = post.preview?.images.first?.source?.url {
            return RedditMarkdown.decodeEntities(src)
        }
        // Thumbnail fallback
        if let thumb = post.thumbnail, thumb.hasPrefix("http"),
           !["self", "default", "nsfw", "spoiler"].contains(thumb) {
            return RedditMarkdown.decodeEntities(thumb)
        }
        return nil
    }

    private func makeHeaderHTML(_ url: String, title: String) async throws -> String {
        // YouTube / Twitter headers would embed; here we localize a direct image.
        if let id = EmbedRewriter.extractYouTubeID(from: url) {
            return "<header style=\"margin-bottom: 1.5em;\">\(EmbedRewriter.youTubeEmbedHTML(videoID: id))</header>"
        }
        guard let remote = URL(string: url), let hash = await store.store(remoteURL: remote, isHeader: true) else {
            return ""
        }
        return ContentFormatter.headerImageHTML(src: "\(ReaderWeb.imageScheme)://\(hash)", alt: title)
    }

    private func stripImage(from html: String, url: String) -> String {
        guard let doc = try? HTMLUtils.parse(html) else { return html }
        try? HTMLUtils.removeImageByURL(doc, url: url)
        // Also drop a bare anchor whose href equals the header url (direct-image link posts).
        if let anchors = try? doc.select("a[href]") {
            for a in anchors where (try? a.attr("href")) == url { try? a.remove() }
        }
        return (try? HTMLUtils.bodyHTML(doc)) ?? html
    }

    // MARK: - Helpers

    private var normalizedSubreddit: String {
        var id = config.identifier.trimmingCharacters(in: .whitespaces)
        if let r = id.range(of: #"(?:reddit\.com)?/?r/(\w+)"#, options: .regularExpression) {
            let match = String(id[r])
            if let nameRange = match.range(of: #"\w+$"#, options: .regularExpression) { return String(match[nameRange]) }
        }
        if id.hasPrefix("/r/") { id = String(id.dropFirst(3)) } else if id.hasPrefix("r/") { id = String(id.dropFirst(2)) }
        return id.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == " " }).first.map(String.init) ?? id
    }

    private func makeClient() throws -> RedditClient {
        if let injectedClient { return injectedClient }
        guard let id = credentials.redditClientID, let secret = credentials.redditClientSecret else {
            throw AggregatorError.missingAPIKey(.reddit)
        }
        return RedditClient(clientID: id, clientSecret: secret, userAgent: AppSettings().redditUserAgent)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditAggregator.swift YanaTests/RedditAggregatorTests.swift
git commit -m "feat: RedditAggregator (posts, comments, header image, filters)"
```

---

## Task 4: `YouTubeClient` — Data API v3 (injectable fetch)

Ports `utils/youtube_client.py`: resolve channel id/handle (search/channels), uploads playlist (channels.contentDetails.relatedPlaylists.uploads → playlistItems → videos), comments (commentThreads order=relevance textFormat=html). Key appended as `key=` query param. Injectable fetch keeps tests hermetic.

**Files:**
- Create: `Yana/Aggregators/Concrete/YouTubeModels.swift`
- Create: `Yana/Aggregators/Concrete/YouTubeClient.swift`
- Test: `YanaTests/YouTubeClientTests.swift`

- [ ] **Step 1: Write the failing test (URL-routed canned JSON)**

Create `YanaTests/YouTubeClientTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("YouTubeClient")
struct YouTubeClientTests {
    private let channelsJSON = """
    {"items":[{"id":"UC123456789012345678901234",
       "snippet":{"title":"My Channel","customUrl":"@mychan",
         "thumbnails":{"high":{"url":"https://img/h.jpg"}}},
       "contentDetails":{"relatedPlaylists":{"uploads":"UU123"}}}]}
    """
    private let playlistJSON = """
    {"items":[{"contentDetails":{"videoId":"vid111aaaaa"}}]}
    """
    private let videosJSON = """
    {"items":[{"id":"vid111aaaaa",
       "snippet":{"title":"Cool Video","description":"Line1\\nLine2","publishedAt":"2023-11-14T00:00:00Z",
         "thumbnails":{"maxres":{"url":"https://img/m.jpg"},"high":{"url":"https://img/h.jpg"}}},
       "statistics":{"viewCount":"100"},"contentDetails":{"duration":"PT5M"}}]}
    """
    private let commentsJSON = """
    {"items":[{"id":"cm1","snippet":{"topLevelComment":{"snippet":{
       "authorDisplayName":"viewer","textDisplay":"Nice <b>vid</b>"}}}}]}
    """

    private func client() -> YouTubeClient {
        YouTubeClient(apiKey: "K") { request in
            let url = request.url!.absoluteString
            if url.contains("/channels") { return Data(self.channelsJSON.utf8) }
            if url.contains("/playlistItems") { return Data(self.playlistJSON.utf8) }
            if url.contains("/videos") { return Data(self.videosJSON.utf8) }
            if url.contains("/commentThreads") { return Data(self.commentsJSON.utf8) }
            if url.contains("/search") { return Data(self.channelsJSON.utf8) }   // unused here
            return Data("{}".utf8)
        }
    }

    @Test func resolveChannelIDForRawID() async throws {
        let id = try await client().resolveChannelID("UC123456789012345678901234")
        #expect(id == "UC123456789012345678901234")
    }

    @Test func fetchChannelDataReturnsUploadsPlaylist() async throws {
        let data = try await client().fetchChannelData("UC123456789012345678901234")
        #expect(data.uploadsPlaylistID == "UU123")
        #expect(data.title == "My Channel")
    }

    @Test func fetchVideosResolvesDetails() async throws {
        let videos = try await client().fetchVideos(playlistID: "UU123", max: 10)
        #expect(videos.count == 1)
        #expect(videos.first?.id == "vid111aaaaa")
        #expect(videos.first?.title == "Cool Video")
        #expect(videos.first?.description.contains("Line1") == true)
        #expect(videos.first?.thumbnailURL == "https://img/m.jpg")    // maxres priority
    }

    @Test func fetchVideoCommentsParsed() async throws {
        let comments = try await client().fetchVideoComments(videoID: "vid111aaaaa", max: 10)
        #expect(comments.first?.author == "viewer")
        #expect(comments.first?.textHTML == "Nice <b>vid</b>")
    }

    @Test func apiKeyAppendedToEveryRequest() async throws {
        var captured: URLRequest?
        let c = YouTubeClient(apiKey: "SECRET") { request in
            captured = request
            return Data(self.channelsJSON.utf8)
        }
        _ = try await c.fetchChannelData("UC123456789012345678901234")
        #expect(captured?.url?.absoluteString.contains("key=SECRET") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/YouTubeClientTests`
Expected: FAIL — `cannot find 'YouTubeClient' in scope`.

- [ ] **Step 3: Implement the models**

Create `Yana/Aggregators/Concrete/YouTubeModels.swift`:

```swift
import Foundation

struct YouTubeChannelData: Sendable {
    var channelID: String
    var title: String
    var customURL: String?
    var uploadsPlaylistID: String?
    var iconURL: String?
}

struct YouTubeVideo: Sendable {
    var id: String
    var title: String
    var description: String
    var publishedAt: Date?
    var thumbnailURL: String?
}

struct YouTubeComment: Sendable {
    var id: String
    var author: String
    var textHTML: String
}

/// Live-search result for the editor picker.
struct YouTubeChannelResult: Sendable, Identifiable {
    var channelID: String        // value saved as the feed identifier
    var title: String
    var handle: String?
    var id: String { channelID }
}
```

- [ ] **Step 4: Implement `YouTubeClient`**

Create `Yana/Aggregators/Concrete/YouTubeClient.swift`:

```swift
import Foundation

/// YouTube Data API v3 client. Injectable fetch closure keeps tests hermetic.
final class YouTubeClient: @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data
    private static let base = "https://www.googleapis.com/youtube/v3"

    private let apiKey: String
    private let fetch: Fetch

    init(apiKey: String, fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) {
        self.apiKey = apiKey
        self.fetch = fetch
    }

    func resolveChannelID(_ identifier: String) async throws -> String {
        let iden = identifier.trimmingCharacters(in: .whitespaces)
        guard !iden.isEmpty else { throw AggregatorError.missingIdentifier }
        if iden.hasPrefix("UC") && iden.count >= 24 { return iden }

        var handle = iden
        if iden.contains("youtube.com") || iden.contains("youtu.be") {
            if let extracted = extractChannelID(fromURL: iden) { return extracted }
            handle = extractHandle(fromURL: iden) ?? iden
        }
        handle = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle

        // search.list by handle, then resolve to a channel id.
        let q = "@\(handle)"
        let data = try await get("search", ["part": "snippet", "q": q, "type": "channel", "maxResults": "10"])
        let search = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let firstID = search.items.compactMap({ $0.id.channelId }).first else {
            throw AggregatorError.contentFetch("Channel handle not found: @\(handle)")
        }
        return firstID
    }

    func fetchChannelData(_ channelID: String) async throws -> YouTubeChannelData {
        let data = try await get("channels", ["part": "contentDetails,snippet", "id": channelID])
        let resp = try JSONDecoder().decode(ChannelsResponse.self, from: data)
        guard let item = resp.items.first else { throw AggregatorError.contentFetch("Channel not found: \(channelID)") }
        let thumbs = item.snippet.thumbnails
        var custom = item.snippet.customUrl
        if let c = custom, !c.hasPrefix("@") { custom = "@\(c)" }
        return YouTubeChannelData(
            channelID: item.id,
            title: item.snippet.title ?? "",
            customURL: custom,
            uploadsPlaylistID: item.contentDetails?.relatedPlaylists?.uploads,
            iconURL: thumbs?.high?.url ?? thumbs?.medium?.url ?? thumbs?.defaultThumb?.url)
    }

    func fetchVideos(playlistID: String, max: Int) async throws -> [YouTubeVideo] {
        let data = try await get("playlistItems", ["part": "snippet,contentDetails",
                                                    "playlistId": playlistID, "maxResults": String(min(50, max))])
        let resp = try JSONDecoder().decode(PlaylistResponse.self, from: data)
        let ids = resp.items.compactMap { $0.contentDetails?.videoId }
        guard !ids.isEmpty else { return [] }
        return try await fetchVideoDetails(Array(ids.prefix(max)))
    }

    func fetchVideoDetails(_ ids: [String]) async throws -> [YouTubeVideo] {
        let data = try await get("videos", ["part": "snippet,statistics,contentDetails", "id": ids.joined(separator: ",")])
        let resp = try JSONDecoder().decode(VideosResponse.self, from: data)
        return resp.items.map { item in
            let t = item.snippet.thumbnails
            return YouTubeVideo(
                id: item.id,
                title: item.snippet.title ?? "",
                description: item.snippet.description ?? "",
                publishedAt: item.snippet.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                thumbnailURL: t?.maxres?.url ?? t?.high?.url ?? t?.medium?.url)
        }
    }

    func fetchVideoComments(videoID: String, max: Int) async throws -> [YouTubeComment] {
        guard max > 0 else { return [] }
        let data = (try? await get("commentThreads", ["part": "snippet", "videoId": videoID,
                                                       "maxResults": String(min(100, max)),
                                                       "order": "relevance", "textFormat": "html"])) ?? Data("{}".utf8)
        let resp = (try? JSONDecoder().decode(CommentThreadsResponse.self, from: data)) ?? CommentThreadsResponse(items: [])
        return resp.items.compactMap { thread in
            let s = thread.snippet.topLevelComment.snippet
            guard let text = s.textDisplay, text != "[deleted]", text != "[removed]" else { return nil }
            return YouTubeComment(id: thread.id, author: s.authorDisplayName ?? "Unknown", textHTML: text)
        }.prefix(max).map { $0 }
    }

    static func searchChannels(query: String, apiKey: String,
                               fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) async -> [YouTubeChannelResult] {
        guard !query.isEmpty, !apiKey.isEmpty else { return [] }
        let client = YouTubeClient(apiKey: apiKey, fetch: fetch)
        guard let data = try? await client.get("search", ["part": "id", "q": query, "type": "channel", "maxResults": "10"]),
              let search = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
        let ids = search.items.compactMap { $0.id.channelId }
        guard !ids.isEmpty,
              let cData = try? await client.get("channels", ["part": "snippet", "id": ids.joined(separator: ",")]),
              let resp = try? JSONDecoder().decode(ChannelsResponse.self, from: cData) else { return [] }
        return resp.items.map {
            var custom = $0.snippet.customUrl
            if let c = custom, !c.hasPrefix("@") { custom = "@\(c)" }
            return YouTubeChannelResult(channelID: $0.id, title: $0.snippet.title ?? "", handle: custom)
        }
    }

    // MARK: - Request + URL helpers

    private func get(_ endpoint: String, _ params: [String: String]) async throws -> Data {
        var comps = URLComponents(string: "\(Self.base)/\(endpoint)")!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "key", value: apiKey)]
        return try await fetch(URLRequest(url: comps.url!))
    }

    private func extractChannelID(fromURL url: String) -> String? {
        if let r = url.range(of: #"channel/(UC[A-Za-z0-9_-]+)"#, options: .regularExpression) {
            return String(url[r]).replacingOccurrences(of: "channel/", with: "")
        }
        return nil
    }
    private func extractHandle(fromURL url: String) -> String? {
        if let r = url.range(of: #"@([A-Za-z0-9_.-]+)"#, options: .regularExpression) {
            return String(url[r]).replacingOccurrences(of: "@", with: "")
        }
        return nil
    }
}

// MARK: - Decoding

private struct Thumbnails: Decodable {
    var maxres: Thumb?; var high: Thumb?; var medium: Thumb?; var defaultThumb: Thumb?
    struct Thumb: Decodable { var url: String? }
    enum CodingKeys: String, CodingKey { case maxres, high, medium, defaultThumb = "default" }
}
private struct SearchResponse: Decodable {
    var items: [Item]
    struct Item: Decodable { var id: ItemID }
    struct ItemID: Decodable { var channelId: String? }
}
private struct ChannelsResponse: Decodable {
    var items: [Item]
    struct Item: Decodable {
        var id: String
        var snippet: Snippet
        var contentDetails: ContentDetails?
    }
    struct Snippet: Decodable { var title: String?; var customUrl: String?; var thumbnails: Thumbnails? }
    struct ContentDetails: Decodable { var relatedPlaylists: Related? }
    struct Related: Decodable { var uploads: String? }
}
private struct PlaylistResponse: Decodable {
    var items: [Item]
    struct Item: Decodable { var contentDetails: CD? }
    struct CD: Decodable { var videoId: String? }
}
private struct VideosResponse: Decodable {
    var items: [Item]
    struct Item: Decodable { var id: String; var snippet: Snippet }
    struct Snippet: Decodable { var title: String?; var description: String?; var publishedAt: String?; var thumbnails: Thumbnails? }
}
private struct CommentThreadsResponse: Decodable {
    var items: [Item]
    struct Item: Decodable { var id: String; var snippet: Snippet }
    struct Snippet: Decodable { var topLevelComment: Top }
    struct Top: Decodable { var snippet: CommentSnippet }
    struct CommentSnippet: Decodable { var authorDisplayName: String?; var textDisplay: String? }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/YouTubeClientTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Concrete/YouTubeModels.swift Yana/Aggregators/Concrete/YouTubeClient.swift YanaTests/YouTubeClientTests.swift
git commit -m "feat: YouTube Data API v3 client (resolve, videos, comments, search)"
```

---

## Task 5: `YouTubeAggregator` — conforms to `Aggregator` directly

Ports `youtube/aggregator.py`: resolve channel → uploads playlist → video details → comments → build `<div class="youtube-description">` (newlines→`<br>`) + comments blockquotes → wrap via `ContentFormatter.format` → prepend `EmbedRewriter.youTubeEmbedHTML`. Throws `.missingAPIKey(.youtube)` when key absent.

**Files:**
- Create: `Yana/Aggregators/Concrete/YouTubeAggregator.swift`
- Test: `YanaTests/YouTubeAggregatorTests.swift`

- [ ] **Step 1: Write the failing test (injected YouTubeClient)**

Create `YanaTests/YouTubeAggregatorTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("YouTubeAggregator")
struct YouTubeAggregatorTests {
    private let channelsJSON = """
    {"items":[{"id":"UC123456789012345678901234",
       "snippet":{"title":"My Channel","customUrl":"@mychan","thumbnails":{"high":{"url":"https://img/h.jpg"}}},
       "contentDetails":{"relatedPlaylists":{"uploads":"UU123"}}}]}
    """
    private let playlistJSON = #"{"items":[{"contentDetails":{"videoId":"vid111aaaaa"}}]}"#
    private let videosJSON = """
    {"items":[{"id":"vid111aaaaa",
       "snippet":{"title":"Cool Video","description":"Line1\\nLine2","publishedAt":"2023-11-14T00:00:00Z",
         "thumbnails":{"maxres":{"url":"https://img/m.jpg"}}},
       "statistics":{"viewCount":"100"},"contentDetails":{"duration":"PT5M"}}]}
    """
    private let commentsJSON = """
    {"items":[{"id":"cm1","snippet":{"topLevelComment":{"snippet":{
       "authorDisplayName":"viewer","textDisplay":"Nice video"}}}}]}
    """

    private func makeAggregator(key: String? = "K") -> YouTubeAggregator {
        let config = FeedConfig(type: .youtube, identifier: "UC123456789012345678901234", dailyLimit: 10,
                                options: .youtube(YouTubeOptions()), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: nil, redditClientSecret: nil, youtubeAPIKey: key)
        let client: YouTubeClient? = key.map { k in
            YouTubeClient(apiKey: k) { request in
                let url = request.url!.absoluteString
                if url.contains("/channels") { return Data(self.channelsJSON.utf8) }
                if url.contains("/playlistItems") { return Data(self.playlistJSON.utf8) }
                if url.contains("/videos") { return Data(self.videosJSON.utf8) }
                if url.contains("/commentThreads") { return Data(self.commentsJSON.utf8) }
                if url.contains("/search") { return Data(self.channelsJSON.utf8) }
                return Data("{}".utf8)
            }
        }
        return YouTubeAggregator(config: config, credentials: creds, client: client)
    }

    @Test func buildsArticleWithEmbedDescriptionAndComments() async throws {
        let a = try #require(try await makeAggregator().aggregate().first)
        #expect(a.title == "Cool Video")
        #expect(a.identifier == "https://www.youtube.com/watch?v=vid111aaaaa")
        #expect(a.content.contains("youtube-embed-container"))      // embed prepended
        #expect(a.content.contains("youtube-nocookie.com/embed/vid111aaaaa"))
        #expect(a.content.contains("youtube-description"))
        #expect(a.content.contains("Line1<br>Line2"))               // newlines -> <br>
        #expect(a.content.contains("Nice video"))                   // comment
        #expect(a.content.contains("<strong>viewer</strong>"))
        #expect(a.content.contains("Source:"))                       // footer
    }

    @Test func missingKeyThrows() async {
        let agg = makeAggregator(key: nil)
        await #expect(throws: AggregatorError.self) { try await agg.aggregate() }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/YouTubeAggregatorTests`
Expected: FAIL — `cannot find 'YouTubeAggregator' in scope`.

- [ ] **Step 3: Implement `YouTubeAggregator`**

Create `Yana/Aggregators/Concrete/YouTubeAggregator.swift`:

```swift
import Foundation

/// YouTube aggregator (Data API v3). Conforms to `Aggregator` directly.
final class YouTubeAggregator: Aggregator, @unchecked Sendable {
    private let config: FeedConfig
    private let credentials: AggregatorCredentials
    private let injectedClient: YouTubeClient?

    init(config: FeedConfig, credentials: AggregatorCredentials, client: YouTubeClient? = nil) {
        self.config = config
        self.credentials = credentials
        self.injectedClient = client
    }

    private var options: YouTubeOptions {
        if case .youtube(let o) = config.options { return o }
        return YouTubeOptions()
    }

    func validate() throws {
        guard !config.identifier.trimmingCharacters(in: .whitespaces).isEmpty else { throw AggregatorError.missingIdentifier }
        guard credentials.youtubeAPIKey != nil else { throw AggregatorError.missingAPIKey(.youtube) }
    }

    func aggregate() async throws -> [AggregatedArticle] {
        try validate()
        let client = try makeClient()
        let channelID = try await client.resolveChannelID(config.identifier)
        let channel = try await client.fetchChannelData(channelID)
        let author = channel.customURL ?? channel.title

        let limit = max(config.dailyLimit, 1)
        let videos: [YouTubeVideo]
        if let uploads = channel.uploadsPlaylistID {
            videos = try await client.fetchVideos(playlistID: uploads, max: limit)
        } else {
            videos = []
        }

        var result: [AggregatedArticle] = []
        for video in videos.prefix(limit) {
            let identifier = "https://www.youtube.com/watch?v=\(video.id)"
            let comments = (try? await client.fetchVideoComments(videoID: video.id, max: options.commentLimit)) ?? []
            let body = buildContentHTML(description: video.description, comments: comments, videoID: video.id)
            let wrapped = ContentFormatter.format(content: body, title: video.title, url: identifier,
                                                  headerHTML: nil, commentsHTML: nil)
            let content = EmbedRewriter.youTubeEmbedHTML(videoID: video.id) + wrapped
            result.append(AggregatedArticle(
                title: video.title, identifier: identifier, url: identifier,
                rawContent: body, content: content,
                date: video.publishedAt ?? .now, author: author, iconURL: video.thumbnailURL))
        }
        return result
    }

    private func buildContentHTML(description: String, comments: [YouTubeComment], videoID: String) -> String {
        let formatted = description.replacingOccurrences(of: "\n", with: "<br>")
        var html = "<div class=\"youtube-description\">\(formatted)</div>"
        if !comments.isEmpty {
            html += "<div class=\"youtube-comments\"><h3>Comments</h3>"
            for c in comments {
                let url = "https://www.youtube.com/watch?v=\(videoID)&lc=\(c.id)"
                html += """
                <blockquote>
                <p><strong>\(escape(c.author))</strong> | <a href="\(url)" target="_blank" rel="noopener">source</a></p>
                <div>\(c.textHTML)</div>
                </blockquote>
                """
            }
            html += "</div>"
        }
        return html
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func makeClient() throws -> YouTubeClient {
        if let injectedClient { return injectedClient }
        guard let key = credentials.youtubeAPIKey else { throw AggregatorError.missingAPIKey(.youtube) }
        return YouTubeClient(apiKey: key)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/YouTubeAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/YouTubeAggregator.swift YanaTests/YouTubeAggregatorTests.swift
git commit -m "feat: YouTubeAggregator (embed + description + comments)"
```

---

## Task 6: `PodcastAggregator` — `RSSPipelineAggregator` subclass

Ports `podcast/aggregator.py`: pick the audio enclosure (audio/* MIME or `.mp3`/`.m4a`/`.ogg`/`.opus`/`.wav`), skip episodes with no audio, build artwork `<div>` (itunesImage / first mediaThumbnail sized to `artworkSize`, downloaded via `ImageStore`), HTML5 `<audio controls preload="metadata">` (gated `includePlayer`), duration line + download link (gated `includeDownloadLink`), then show notes. Duration parses HH:MM:SS / MM:SS / seconds.

**Files:**
- Create: `Yana/Aggregators/Concrete/PodcastAggregator.swift`
- Test: `YanaTests/PodcastAggregatorTests.swift`

- [ ] **Step 1: Write the failing test (inject entries + ImageStore)**

Create `YanaTests/PodcastAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("PodcastAggregator")
struct PodcastAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    final class StubPodcast: PodcastAggregator, @unchecked Sendable {
        let entries: [FeedEntry]
        init(entries: [FeedEntry], options: PodcastOptions, store: ImageStore) {
            self.entries = entries
            super.init(config: FeedConfig(type: .podcast, identifier: "https://p.com/feed", dailyLimit: 20,
                                          options: .podcast(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
    }

    private func entry(enclosures: [FeedEnclosure], duration: String? = "1:02:03",
                       itunesImage: String? = "https://p.com/art.jpg") -> FeedEntry {
        FeedEntry(title: "Ep 1", link: "https://p.com/1", content: nil,
                  summary: "<p>Notes</p>", entryDescription: nil, published: .now, author: "Host",
                  enclosures: enclosures, itunesDuration: duration, itunesImage: itunesImage, mediaThumbnails: [])
    }

    @Test func buildsPlayerArtworkDurationAndNotes() async throws {
        let e = entry(enclosures: [FeedEnclosure(url: "https://p.com/1.mp3", type: "audio/mpeg")])
        let agg = StubPodcast(entries: [e], options: PodcastOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("<audio controls"))
        #expect(a.content.contains("https://p.com/1.mp3"))
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))    // artwork cached
        #expect(a.content.contains("Duration: 1:02:03"))
        #expect(a.content.contains("Download Episode"))
        #expect(a.content.contains("Show Notes"))
        #expect(a.content.contains("Notes"))
    }

    @Test func skipsEpisodesWithoutAudioEnclosure() async throws {
        let e = entry(enclosures: [FeedEnclosure(url: "https://p.com/1.pdf", type: "application/pdf")])
        let agg = StubPodcast(entries: [e], options: PodcastOptions(), store: tempStore())
        #expect(try await agg.aggregate().isEmpty)
    }

    @Test func gatesPlayerAndDownloadLink() async throws {
        var opts = PodcastOptions(); opts.includePlayer = false; opts.includeDownloadLink = false
        let e = entry(enclosures: [FeedEnclosure(url: "https://p.com/1.m4a", type: nil)])  // by extension
        let agg = StubPodcast(entries: [e], options: opts, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(!a.content.contains("<audio"))
        #expect(!a.content.contains("Download Episode"))
        #expect(a.content.contains("Show Notes"))
    }

    @Test func parsesSecondsAndMinuteSecondDurations() async throws {
        let e1 = entry(enclosures: [FeedEnclosure(url: "https://p.com/a.mp3", type: "audio/mpeg")], duration: "125")
        let a1 = try #require(try await StubPodcast(entries: [e1], options: PodcastOptions(), store: tempStore()).aggregate().first)
        #expect(a1.content.contains("Duration: 2:05"))
        let e2 = entry(enclosures: [FeedEnclosure(url: "https://p.com/b.mp3", type: "audio/mpeg")], duration: "5:09")
        let a2 = try #require(try await StubPodcast(entries: [e2], options: PodcastOptions(), store: tempStore()).aggregate().first)
        #expect(a2.content.contains("Duration: 5:09"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/PodcastAggregatorTests`
Expected: FAIL — `cannot find 'PodcastAggregator' in scope`.

- [ ] **Step 3: Implement `PodcastAggregator`**

Create `Yana/Aggregators/Concrete/PodcastAggregator.swift`:

```swift
import Foundation

/// Podcast aggregator: an RSS pipeline that builds artwork / HTML5 audio player / duration /
/// download / show-notes markup. Episodes without an audio enclosure are skipped.
/// (Native AVPlayer is out of scope — HTML5 `<audio>` only.)
class PodcastAggregator: RSSPipelineAggregator, @unchecked Sendable {
    private var podcastOptions: PodcastOptions {
        if case .podcast(let o) = config.options { return o }
        return PodcastOptions()
    }

    /// Episodes with no audio enclosure are dropped at make-time via `AggregatorError.articleSkip`
    /// (the base pipeline catches it and omits the article).
    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        guard let (mediaURL, mediaType) = pickAudioEnclosure(entry) else {
            throw AggregatorError.articleSkip(statusCode: 0)
        }
        let opts = podcastOptions
        var parts: [String] = []

        // Artwork (downloaded + cached).
        if let imageURL = artworkURL(entry), let remote = URL(string: imageURL),
           let hash = await store.store(remoteURL: remote, isHeader: true) {
            parts.append("""
            <div data-sanitized-class="podcast-artwork" style="margin-bottom: 1em;">\
            <img src="\(ReaderWeb.imageScheme)://\(hash)" alt="Episode artwork" \
            style="max-width: \(opts.artworkSize)px; height: auto; border-radius: 8px;"></div>
            """)
        }

        // Player (open div if included).
        if opts.includePlayer {
            parts.append("""
            <div data-sanitized-class="podcast-player" style="margin-bottom: 1em;">\
            <audio controls preload="metadata" style="width: 100%;">\
            <source src="\(mediaURL)" type="\(mediaType)">\
            Your browser does not support the audio element.</audio>
            """)
        }

        // Duration + download meta.
        var meta: [String] = []
        if let seconds = parseDuration(entry.itunesDuration) {
            meta.append("<span data-sanitized-class=\"podcast-duration\">Duration: \(formatDuration(seconds))</span>")
        }
        if opts.includeDownloadLink {
            meta.append("<a href=\"\(mediaURL)\" data-sanitized-class=\"podcast-download\" download>Download Episode</a>")
        }
        if (opts.includePlayer || opts.includeDownloadLink) && !meta.isEmpty {
            parts.append("<div style=\"margin-top: 0.5em; font-size: 0.9em; color: #666;\">\(meta.joined(separator: " | "))</div>")
        }
        if opts.includePlayer { parts.append("</div>") }

        // Show notes.
        let notes = entry.summary ?? entry.entryDescription ?? entry.content ?? ""
        if !notes.isEmpty {
            parts.append("<div data-sanitized-class=\"podcast-description\"><h4>Show Notes</h4>\(notes)</div>")
        }

        var article = article
        let combined = parts.joined(separator: "\n")
        // Reuse the base content pipeline (sanitize/clean/wrap with footer); artwork already localized.
        article.content = try await processContent(combined, article: article, headerHTML: nil)
        return article
    }

    // MARK: - Enclosure + media helpers

    private func pickAudioEnclosure(_ entry: FeedEntry) -> (url: String, type: String)? {
        let audioExts = [".mp3", ".m4a", ".ogg", ".opus", ".wav"]
        for enc in entry.enclosures {
            let type = enc.type ?? ""
            let isAudio = type.hasPrefix("audio/") || audioExts.contains { enc.url.lowercased().hasSuffix($0) }
            if isAudio { return (enc.url, type.isEmpty ? "audio/mpeg" : type) }
        }
        return nil
    }

    private func artworkURL(_ entry: FeedEntry) -> String? {
        if let img = entry.itunesImage, !img.isEmpty { return img }
        return entry.mediaThumbnails.first
    }

    func parseDuration(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.range(of: #"^\d+$"#, options: .regularExpression) != nil { return Int(s) }
        let parts = s.split(separator: ":").map { Int($0) }
        if parts.count == 3, let h = parts[0], let m = parts[1], let sec = parts[2] { return h * 3600 + m * 60 + sec }
        if parts.count == 2, let m = parts[0], let sec = parts[1] { return m * 60 + sec }
        return nil
    }

    func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/PodcastAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/PodcastAggregator.swift YanaTests/PodcastAggregatorTests.swift
git commit -m "feat: PodcastAggregator (artwork, audio player, duration, show notes)"
```

---

## Task 7: Register reddit / youtube / podcast in the registry

The registry resolves credentials (the service already passes `AggregatorCredentials`). Add the three cases to `makeAggregator`.

**Files:**
- Modify: `Yana/Aggregators/AggregatorRegistry.swift`
- Test: `YanaTests/AggregatorRegistrySocialTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregatorRegistrySocialTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry — social/media")
struct AggregatorRegistrySocialTests {
    @Test func buildsRedditYouTubePodcast() {
        let reddit = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 20,
                                options: .reddit(RedditOptions()), collectedToday: 0)
        let youtube = FeedConfig(type: .youtube, identifier: "UCabc", dailyLimit: 20,
                                 options: .youtube(YouTubeOptions()), collectedToday: 0)
        let podcast = FeedConfig(type: .podcast, identifier: "https://p.com/feed", dailyLimit: 20,
                                 options: .podcast(PodcastOptions()), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: "k")
        #expect(AggregatorRegistry.shared.makeAggregator(reddit, credentials: creds) is RedditAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(youtube, credentials: creds) is YouTubeAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(podcast, credentials: creds) is PodcastAggregator)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregatorRegistrySocialTests`
Expected: FAIL — registry returns `nil` for reddit/youtube/podcast.

- [ ] **Step 3: Wire the registry**

In `Yana/Aggregators/AggregatorRegistry.swift`, add the cases to `makeAggregator` (alongside 4c's `feedContent`/`fullWebsite`):

```swift
        case .reddit: return RedditAggregator(config: config, credentials: credentials)
        case .youtube: return YouTubeAggregator(config: config, credentials: credentials)
        case .podcast: return PodcastAggregator(config: config, credentials: credentials)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregatorRegistrySocialTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS. (If the 4c `unregisteredTypeStillNil` test used `.reddit`, change it to a still-unregistered type — e.g. `.heise` — so it still asserts the nil path.)

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/AggregatorRegistry.swift YanaTests/AggregatorRegistrySocialTests.swift YanaTests/AggregatorRegistryGenericTests.swift
git commit -m "feat: register reddit + youtube + podcast aggregators"
```

---

## Task 8: Live-search identifier picker in `FeedEditorView`

For reddit/youtube identifiers, add a lightweight search sheet: a search field that calls the static search (`RedditClient.searchSubreddits` / `YouTubeClient.searchChannels`) and lists results to pick. Picking sets `model.identifier`.

**Files:**
- Create: `Yana/Views/Config/IdentifierSearchView.swift`
- Modify: `Yana/Views/Config/FeedEditorView.swift`
- Test: `YanaTests/IdentifierSearchTests.swift`

- [ ] **Step 1: Write the failing test (pure search-state model)**

Drive the testable logic through an `@MainActor @Observable` `IdentifierSearchModel` so the view stays a thin shell (the static searches are exercised in the client tests; here we test result mapping + selection).

Create `YanaTests/IdentifierSearchTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("IdentifierSearch")
struct IdentifierSearchTests {
    @Test func redditResultsMapToRows() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0") { _ in
            [RedditSubredditResult(displayName: "swift", title: "Swift", subscribers: 12345)]
        } youtubeSearch: { _ in [] }
        await model.search("swi")
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.value == "swift")
        #expect(model.rows.first?.label.contains("Swift") == true)
    }

    @Test func youtubeResultsMapToRows() async {
        let model = IdentifierSearchModel(kind: .youtubeChannel, credentials: .init(), userAgent: "Yana/1.0") { _ in
            []
        } youtubeSearch: { _ in
            [YouTubeChannelResult(channelID: "UCabc", title: "Cool", handle: "@cool")]
        }
        await model.search("cool")
        #expect(model.rows.first?.value == "UCabc")
        #expect(model.rows.first?.label.contains("Cool") == true)
    }

    @Test func emptyQueryClearsRows() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0") { _ in
            [RedditSubredditResult(displayName: "x", title: "X", subscribers: 1)]
        } youtubeSearch: { _ in [] }
        await model.search("x")
        await model.search("")
        #expect(model.rows.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/IdentifierSearchTests`
Expected: FAIL — `cannot find 'IdentifierSearchModel' in scope`.

- [ ] **Step 3: Implement the model + view**

Create `Yana/Views/Config/IdentifierSearchView.swift`:

```swift
import SwiftUI

/// A pickable search result row (value is saved to the feed identifier).
struct IdentifierSearchRow: Identifiable, Sendable {
    var value: String
    var label: String
    var id: String { value }
}

/// Testable search state: maps reddit/youtube live-search results into rows.
/// The two search closures default to the real static searches but are injectable for tests.
@MainActor
@Observable
final class IdentifierSearchModel {
    let kind: AggregatorIdentifierKind
    var rows: [IdentifierSearchRow] = []
    var isSearching = false

    private let redditSearch: (String) async -> [RedditSubredditResult]
    private let youtubeSearch: (String) async -> [YouTubeChannelResult]

    init(kind: AggregatorIdentifierKind,
         credentials: AggregatorCredentials,
         userAgent: String,
         apiKey: String? = nil,
         redditSearch: ((String) async -> [RedditSubredditResult])? = nil,
         youtubeSearch: ((String) async -> [YouTubeChannelResult])? = nil) {
        self.kind = kind
        self.redditSearch = redditSearch ?? { query in
            await RedditClient.searchSubreddits(query: query, credentials: credentials, userAgent: userAgent)
        }
        self.youtubeSearch = youtubeSearch ?? { query in
            await YouTubeClient.searchChannels(query: query, apiKey: apiKey ?? "")
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { rows = []; return }
        isSearching = true
        defer { isSearching = false }
        switch kind {
        case .subreddit:
            rows = (await redditSearch(trimmed)).map {
                IdentifierSearchRow(value: $0.displayName,
                                    label: "r/\($0.displayName) — \($0.title) (\($0.subscribers) subs)")
            }
        case .youtubeChannel:
            rows = (await youtubeSearch(trimmed)).map {
                IdentifierSearchRow(value: $0.channelID,
                                    label: $0.handle.map { "\($0.title) (\($0))" } ?? "\($0.title) (\($0.channelID))" )
            }
        default:
            rows = []
        }
    }
}

/// A sheet that searches subreddits / YouTube channels and lets the user pick one.
struct IdentifierSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: IdentifierSearchModel
    @State private var query = ""
    let onPick: (String) -> Void

    init(kind: AggregatorIdentifierKind, onPick: @escaping (String) -> Void) {
        let creds = AggregatorCredentials.resolved()
        let apiKey = creds.youtubeAPIKey
        _model = State(initialValue: IdentifierSearchModel(
            kind: kind, credentials: creds, userAgent: AppSettings().redditUserAgent, apiKey: apiKey))
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            List(model.rows) { row in
                Button {
                    onPick(row.value)
                    dismiss()
                } label: {
                    Text(row.label)
                }
            }
            .overlay {
                if model.isSearching { ProgressView() }
                else if model.rows.isEmpty { ContentUnavailableView("Search", systemImage: "magnifyingglass") }
            }
            .navigationTitle("Search")
            .searchable(text: $query)
            .onSubmit(of: .search) { Task { await model.search(query) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
```

In `Yana/Views/Config/FeedEditorView.swift`, add a search button next to the identifier field for searchable kinds. Add `@State private var showingSearch = false` and replace the identifier `TextField` block:

```swift
                if model.type.identifierKind != .none {
                    HStack {
                        TextField(identifierLabel, text: $model.identifier)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if model.type.identifierKind == .subreddit || model.type.identifierKind == .youtubeChannel {
                            Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
```

And attach the sheet to the `Form` (e.g. after `.navigationTitle`):

```swift
        .sheet(isPresented: $showingSearch) {
            IdentifierSearchView(kind: model.type.identifierKind) { picked in
                model.identifier = picked
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/IdentifierSearchTests`
Expected: PASS.

- [ ] **Step 5: Verify the editor compiles + full suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.
Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/Config/IdentifierSearchView.swift Yana/Views/Config/FeedEditorView.swift YanaTests/IdentifierSearchTests.swift
git commit -m "feat: live subreddit/channel search picker in feed editor"
```

---

## Self-Review

**Spec coverage (§4.3):**
- **Reddit (T1–T3):** app-only OAuth (POST access_token, Basic auth, User-Agent, bearer GETs to `oauth.reddit.com`); AutoModerator + age (`minAgeHours`) + `minComments` filters; comments best-sorted, bot/deleted filtered, capped at `commentLimit`, blockquote markup (`<strong>author</strong> | source` + markdown body); gallery / crosspost / link / image / video handling; header image (gallery → direct → preview → thumbnail) via `ImageStore`, deduped from body; `includeHeaderImage`; minimal Reddit-markdown converter; `.missingAPIKey(.reddit)`; `searchSubreddits` static for the editor.
- **YouTube (T4–T5):** Data API v3 resolve (id/handle/url via search/channels) → uploads playlist → playlistItems → videos → commentThreads (order=relevance, textFormat=html); `<div class="youtube-description">` with `<br>`; comment blockquotes; embed prepended via `EmbedRewriter.youTubeEmbedHTML`; thumbnail priority maxres→high→medium; `.missingAPIKey(.youtube)`; `searchChannels` static.
- **Podcast (T6):** `RSSPipelineAggregator` subclass; enclosure pick (audio MIME / ext); skip no-audio; artwork sized to `artworkSize` via `ImageStore`; HTML5 `<audio>` gated by `includePlayer`; duration + download gated by `includeDownloadLink`; duration parse HH:MM:SS / MM:SS / seconds; show notes.
- **Registry (T7)** + **editor pickers (T8)** wire everything end-to-end.

**Injectable fetch / hermetic tests:** every client takes `@Sendable (URLRequest) async throws -> Data` defaulting to `HTTPClient.fetchJSON`; aggregators accept an optional injected client; `ImageStore` uses a temp dir + canned PNG. No test touches the network.

**Placeholders:** none — complete Swift or an exact command + expected output in every step.

**Type consistency:** uses the 4a contract (`FeedConfig`, `Aggregator` [`validate` + async `aggregate`], `AggregatorCredentials.{redditClientID,redditClientSecret,youtubeAPIKey}`, `AggregatorError.missingAPIKey(.reddit/.youtube)`, `AggregatorRegistry.makeAggregator`), the 4b contract (`HTTPClient.fetchJSON`, `FeedEntry`, `ContentFormatter.format`/`headerImageHTML`, `EmbedRewriter.youTubeEmbedHTML`/`extractYouTubeID`, `ImageStore.store`, `ReaderWeb.imageScheme`, `HTMLUtils`), and the 4c contract (`RSSPipelineAggregator` `config`/`store`/`processContent`/`fetchEntries`/`enrich` + `AggregatorError.articleSkip` to omit an article). Options read from `AggregatorOptions.{reddit,youtube,podcast}` verbatim; `AppSettings().redditUserAgent` supplies the UA.

**Fidelity risks (call out for the implementer):**
1. **Reddit markdown converter** is the highest-risk port — Python's `markdown` library is replaced by a hand-rolled subset. The plan covers paragraphs/links/bold/italic/code/blockquotes/lists/strikethrough/superscript/spoilers/preview-images/auto-linkify, but does NOT replicate fenced code blocks, tables, or nested lists. This is acceptable for parity-of-output on typical Reddit selftext/comments; if a feed surfaces tables, they degrade to paragraphs. The regex-based linkify uses a lookbehind to avoid double-linking inside existing anchors — verify on real comment bodies.
2. **Reddit OAuth** — the server used PRAW; this ports to raw application-only OAuth. Token caching is per-client-instance (one run). The `comments.json` response is `[postListing, commentListing]`; index 1 holds top-level comments, and the trailing `{"kind":"more"}` child has no comment fields (decoded as optional + skipped). Reddit rate-limits app-only tokens to ~10 req/min/IP; the flat run cap keeps this modest, but a large `dailyLimit` with per-post comment fetches could hit limits — out of scope to throttle here.
3. **Reddit header-image link-page scraping** (server Priority 5: fetch the linked page for `og:image`) is intentionally NOT ported — it requires a synchronous HTML fetch + extractor per post. The chain stops at preview/thumbnail, matching the 4b header strategy boundary; this is a minor divergence noted for review.
4. **YouTube** — `search.list` quota is expensive (100 units); resolving a handle costs a search per run unless the identifier is already a `UC…` id. The editor picker stores the resolved `channelID` as the identifier, which avoids the per-run search; document this so users pick from search rather than typing handles.
5. **Podcast** reuses the base `processContent` (sanitize/clean/footer) on already-localized artwork; the base `rewriteImages` will also localize any `<img>` inside show notes — consistent with decision 3 (all images downloaded).
