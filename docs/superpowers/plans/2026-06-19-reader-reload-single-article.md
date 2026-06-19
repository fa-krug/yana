# Reader Reload: Single-Article-Only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the reader's "Reload" action re-fetch and write only the current article for every source type, never reloading the whole feed.

**Architecture:** Give every concrete `Aggregator` a real `refetch(_ seed:)` that fetches just the one item, then remove both `forceReload(feed:)` fallbacks from `AggregationService.forceReload(article:)`. The feed-wide path stays but is only reachable from the Feeds screen.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`import Testing`), `@MainActor`.

## Global Constraints

- Platform: iOS 26.0+; Swift 6 strict concurrency, `@MainActor` where existing code uses it.
- Tests use the Swift Testing framework (`import Testing`, `@Test`, `#expect`, `#require`).
- Run tests: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- No new user-facing strings are added in this plan (the existing `RefreshOutcome` "no new content" path is reused), so no `Localizable.xcstrings` changes are required.
- Aggregators are `@unchecked Sendable`, constructed per-run; clients (`RedditClient`, `YouTubeClient`) take an injectable `fetch` closure for hermetic tests.

---

### Task 1: RSS/Podcast single-entry refetch

**Files:**
- Modify: `Yana/Aggregators/Concrete/RSSPipelineAggregator.swift:42-44` (replace the `nil` stub)
- Test: `YanaTests/RSSPipelineAggregatorTests.swift` (add tests; update the existing `refetchDefaultsToNilForRSSPipeline` test)

**Interfaces:**
- Consumes: existing `fetchEntries() -> [FeedEntry]`, `makeArticle(from:) -> AggregatedArticle`, `enrich(_:entry:) -> AggregatedArticle`; `FeedEntry.link: String`; `AggregatedArticle.identifier: String`.
- Produces: `RSSPipelineAggregator.refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle?` — returns the enriched article whose feed entry's `link` equals `seed.identifier`, or `nil` when no entry matches. Inherited unchanged by `FeedContentAggregator` and `PodcastAggregator`. `FullWebsiteAggregator` keeps its own override.

- [ ] **Step 1: Write the failing tests**

In `YanaTests/RSSPipelineAggregatorTests.swift`, add two tests inside the `RSSPipelineAggregatorTests` suite (the `StubFeed` helper that overrides `fetchEntries` already exists in this file):

```swift
@Test func refetchReturnsOnlyMatchingEntry() async throws {
    let entries = [
        FeedEntry(title: "One", link: "https://x.com/1", content: "<p>One body</p>",
                  summary: nil, entryDescription: nil, published: .now, author: "Al",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: []),
        FeedEntry(title: "Two", link: "https://x.com/2", content: "<p>Two body</p>",
                  summary: nil, entryDescription: nil, published: .now, author: "Al",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    ]
    let agg = StubFeed(entries: entries, config: config(), store: tempStore())
    let seed = AggregatedArticle(title: "Two", identifier: "https://x.com/2", url: "https://x.com/2",
                                 rawContent: "", content: "", date: .now, author: "", iconURL: nil)
    let result = try #require(try await agg.refetch(seed))
    #expect(result.identifier == "https://x.com/2")
    #expect(result.content.contains("Two body"))
}

@Test func refetchReturnsNilWhenEntryGone() async throws {
    let entries = [
        FeedEntry(title: "One", link: "https://x.com/1", content: "<p>One body</p>",
                  summary: nil, entryDescription: nil, published: .now, author: "Al",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    ]
    let agg = StubFeed(entries: entries, config: config(), store: tempStore())
    let seed = AggregatedArticle(title: "Gone", identifier: "https://x.com/missing", url: "https://x.com/missing",
                                 rawContent: "", content: "", date: .now, author: "", iconURL: nil)
    let result = try await agg.refetch(seed)
    #expect(result == nil)
}
```

Then **replace** the existing `refetchDefaultsToNilForRSSPipeline` test (it asserted the old `nil` stub and would now hit the network via `fetchEntries`) with one that uses a stubbed-entries feed:

```swift
@Test func refetchReturnsNilWhenNoEntriesMatch() async throws {
    let agg = StubFeed(entries: [], config: config(), store: tempStore())
    let seed = AggregatedArticle(title: "T", identifier: "id", url: "u", rawContent: "",
                                 content: "c", date: .now, author: "", iconURL: nil)
    let result = try await agg.refetch(seed)
    #expect(result == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RSSPipelineAggregatorTests 2>&1 | tail -30`
Expected: `refetchReturnsOnlyMatchingEntry` FAILS (`#require` on nil — the default stub returns nil); the two nil tests pass trivially.

- [ ] **Step 3: Implement the refetch**

In `Yana/Aggregators/Concrete/RSSPipelineAggregator.swift`, replace lines 42-44:

```swift
    /// Default: cannot re-fetch a single item in isolation (RSS content lives in the feed payload).
    /// `FullWebsiteAggregator` overrides this with a real per-URL re-fetch.
    func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? { nil }
```

with:

```swift
    /// Re-fetch one known article by re-downloading the feed and enriching only the entry whose
    /// link matches the seed identifier. The network fetch pulls the whole feed (RSS content lives
    /// in the feed payload), but only the matching entry is returned. `nil` when the entry is gone.
    /// `FullWebsiteAggregator` overrides this with a per-URL re-scrape.
    func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? {
        let entries = try await fetchEntries()
        guard let entry = entries.first(where: { $0.link == seed.identifier }) else { return nil }
        return try await enrich(makeArticle(from: entry), entry: entry)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RSSPipelineAggregatorTests 2>&1 | tail -30`
Expected: PASS (all RSS pipeline tests, including the new and replaced ones).

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/RSSPipelineAggregator.swift YanaTests/RSSPipelineAggregatorTests.swift
git commit -m "feat(reader): RSS/podcast refetch returns only the matching entry"
```

---

### Task 2: YouTube single-video refetch

**Files:**
- Modify: `Yana/Aggregators/Concrete/YouTubeAggregator.swift` (add `refetch`)
- Test: `YanaTests/YouTubeAggregatorTests.swift` (add tests)

**Interfaces:**
- Consumes: `EmbedRewriter.extractYouTubeID(from:) -> String?`; `YouTubeClient.fetchVideoDetails(_ ids: [String]) -> [YouTubeVideo]`; `YouTubeClient.fetchVideoComments(videoID:max:) -> [YouTubeComment]`; existing private `makeClient() throws -> YouTubeClient`, `buildContentHTML(video:videoID:comments:)`, `options.commentLimit`; `EmbedRewriter.youTubeEmbedHTML(videoID:)`; `ContentFormatter.format(content:title:url:headerHTML:commentsHTML:)`.
- Produces: `YouTubeAggregator.refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle?` — rebuilds one video's article (embed + description + comments), reusing `seed.author`; `nil` when the video ID can't be parsed or the video is gone.

- [ ] **Step 1: Write the failing tests**

In `YanaTests/YouTubeAggregatorTests.swift`, add to the suite (the `videosJSON`/`commentsJSON` fixtures and `makeAggregator(key:)` helper already exist):

```swift
@Test func refetchRebuildsSingleVideo() async throws {
    let seed = AggregatedArticle(title: "Old title", identifier: "https://www.youtube.com/watch?v=vid111aaaaa",
                                 url: "https://www.youtube.com/watch?v=vid111aaaaa",
                                 rawContent: "", content: "OLD", date: .now, author: "@mychan", iconURL: nil)
    let a = try #require(try await makeAggregator(key: "K").refetch(seed))
    #expect(a.identifier == "https://www.youtube.com/watch?v=vid111aaaaa")
    #expect(a.title == "Cool Video")                                 // refreshed from the API
    #expect(a.content.contains("youtube-nocookie.com/embed/vid111aaaaa"))
    #expect(a.content.contains("Line1<br>Line2"))                    // description
    #expect(a.content.contains("Nice video"))                        // comments
    #expect(a.author == "@mychan")                                   // carried from seed (no channel resolve)
}

@Test func refetchReturnsNilForUnparseableURL() async throws {
    let seed = AggregatedArticle(title: "x", identifier: "not-a-video", url: "https://example.com/x",
                                 rawContent: "", content: "", date: .now, author: "", iconURL: nil)
    let result = try await makeAggregator(key: "K").refetch(seed)
    #expect(result == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/YouTubeAggregatorTests 2>&1 | tail -30`
Expected: `refetchRebuildsSingleVideo` FAILS (`#require` on nil — base default `refetch` returns nil).

- [ ] **Step 3: Implement the refetch**

In `Yana/Aggregators/Concrete/YouTubeAggregator.swift`, add this method right after `aggregate()` (before `logoImageURL()`):

```swift
    func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? {
        guard let videoID = EmbedRewriter.extractYouTubeID(from: seed.url) else { return nil }
        let client = try makeClient()
        guard let video = try await client.fetchVideoDetails([videoID]).first else { return nil }
        let url = "https://www.youtube.com/watch?v=\(video.id)"
        let comments = (try? await client.fetchVideoComments(videoID: video.id, max: options.commentLimit)) ?? []
        let body = buildContentHTML(video: video, videoID: video.id, comments: comments)
        let embed = EmbedRewriter.youTubeEmbedHTML(videoID: video.id)
        let content = ContentFormatter.format(content: embed + body, title: video.title, url: url,
                                              headerHTML: nil, commentsHTML: nil)
        return AggregatedArticle(
            title: video.title, identifier: url, url: url,
            rawContent: body, content: content,
            date: video.publishedAt ?? Date(), author: seed.author, iconURL: video.thumbnailURL)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/YouTubeAggregatorTests 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/YouTubeAggregator.swift YanaTests/YouTubeAggregatorTests.swift
git commit -m "feat(reader): YouTube refetch rebuilds a single video"
```

---

### Task 3: RedditClient single-post fetch

**Files:**
- Modify: `Yana/Aggregators/Concrete/RedditClient.swift` (add `fetchPost`; add a private decoding envelope)
- Test: `YanaTests/RedditClientTests.swift` (add a test)

**Interfaces:**
- Consumes: existing private `authorizedGET(_ url:) -> Data`, static `encodePath(_:)`; `RedditPostData` (Decodable).
- Produces: `RedditClient.fetchPost(subreddit: String, postID: String) async throws -> RedditPostData?` — hits `/comments/<postID>.json` and decodes the post from listing element 0; `nil` when the listing has no post child. (The `subreddit` parameter mirrors `fetchComments`'s signature for call-site symmetry even though the comments endpoint is keyed only by post ID.)

- [ ] **Step 1: Write the failing test**

In `YanaTests/RedditClientTests.swift`, add a test that injects the two-element `/comments` response shape (element 0 = post listing, element 1 = comments):

```swift
@Test func fetchPostDecodesPostFromFirstListing() async throws {
    let json = """
    [ {"data":{"children":[
        {"data":{"id":"p1","title":"Hello","selftext":"Body","url":"https://e.com",
                 "permalink":"/r/swift/comments/p1/hello/","created_utc":1700000000,
                 "author":"alice","score":5,"num_comments":2,"is_self":true}}
      ]}},
      {"data":{"children":[
        {"kind":"t1","data":{"id":"c1","body":"Nice","author":"bob","score":1,"permalink":"/r/swift/comments/p1/hello/c1/"}}
      ]}} ]
    """
    let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
        let url = request.url!.absoluteString
        if url.contains("access_token") { return Data(#"{"access_token":"TKN"}"#.utf8) }
        return Data(json.utf8)
    }
    let post = try #require(try await client.fetchPost(subreddit: "swift", postID: "p1"))
    #expect(post.id == "p1")
    #expect(post.title == "Hello")
    #expect(post.author == "alice")
}

@Test func fetchPostReturnsNilWhenNoPost() async throws {
    let json = """
    [ {"data":{"children":[]}}, {"data":{"children":[]}} ]
    """
    let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
        let url = request.url!.absoluteString
        if url.contains("access_token") { return Data(#"{"access_token":"TKN"}"#.utf8) }
        return Data(json.utf8)
    }
    let post = try await client.fetchPost(subreddit: "swift", postID: "p1")
    #expect(post == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditClientTests 2>&1 | tail -30`
Expected: FAIL to compile (`fetchPost` does not exist).

- [ ] **Step 3: Implement `fetchPost` and its decoding envelope**

In `Yana/Aggregators/Concrete/RedditClient.swift`, add the method right after `fetchComments` (around line 108):

```swift
    /// Re-fetch a single known post. The `/comments/<id>.json` endpoint returns
    /// `[postListing, commentListing]`; index 0 holds the post. Returns `nil` when the post is gone.
    func fetchPost(subreddit: String, postID: String) async throws -> RedditPostData? {
        guard let url = URL(string:
            "https://oauth.reddit.com/comments/\(Self.encodePath(postID)).json?raw_json=1")
        else { throw AggregatorError.contentFetch("invalid post id") }
        let data = try await authorizedGET(url)
        return try JSONDecoder().decode(RedditPostResponse.self, from: data).post
    }
```

Then add this private envelope next to the other `private struct Reddit…` decoders (near line 185). It uses an unkeyed container so element 1 (comments) is never decoded — decoding it as a post listing would throw:

```swift
/// Decodes only element 0 (the post listing) of a `/comments/<id>.json` response.
private struct RedditPostResponse: Decodable {
    let post: RedditPostData?
    private struct PostListing: Decodable {
        let data: ListingData
        struct ListingData: Decodable { let children: [Child] }
        struct Child: Decodable { let data: RedditPostData }
    }
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let listing = try container.decode(PostListing.self)   // element 0; element 1 left undecoded
        post = listing.data.children.first?.data
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditClientTests 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditClient.swift YanaTests/RedditClientTests.swift
git commit -m "feat(reader): add RedditClient.fetchPost for single-post fetch"
```

---

### Task 4: Reddit single-post refetch

**Files:**
- Modify: `Yana/Aggregators/Concrete/RedditAggregator.swift` (extract a single-post builder from `aggregate()`; add `refetch`)
- Test: `YanaTests/RedditAggregatorTests.swift` (add tests)

**Interfaces:**
- Consumes: `RedditClient.fetchPost(subreddit:postID:) -> RedditPostData?` (Task 3); existing private `makeClient()`, `buildContent(post:isCrossPost:client:)`, `headerImageURL(for:)`, `makeHeaderHTML(_:title:)`, `stripImage(from:url:)`, `normalizedSubreddit`, `options`; `ContentFormatter.format(...)`; `RedditMarkdown.decodeEntities(_:)`.
- Produces: `RedditAggregator.refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle?` — rebuilds one post's article via `fetchPost`; `nil` when the post ID can't be parsed from `seed.identifier` or the post is gone. Also introduces private `buildArticle(from post: RedditPostData, client: RedditClient) async throws -> AggregatedArticle`, used by both `aggregate()` and `refetch`.

- [ ] **Step 1: Write the failing tests**

In `YanaTests/RedditAggregatorTests.swift`, add a refetch helper and tests. The `tempStore()` helper and JSON fixtures already exist; this helper wires `fetchPost`'s endpoint to a post-shaped response:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditAggregatorTests 2>&1 | tail -30`
Expected: `refetchRebuildsSinglePost` FAILS (`#require` on nil — base default `refetch` returns nil).

- [ ] **Step 3: Extract `buildArticle` and implement `refetch`**

In `Yana/Aggregators/Concrete/RedditAggregator.swift`, refactor `aggregate()`'s loop body (lines 60-75) to call a new shared builder, then add `refetch`. Replace the loop body (the part from `let permalink = …` through the `result.append(…)`) so the loop becomes:

```swift
        for post in posts {
            let original = post.crosspostParentList?.first ?? post
            let date = Date(timeIntervalSince1970: original.createdUTC)
            if date < twoMonths { continue }
            if opts.minAgeHours > 0 && date > cutoff { continue }
            if post.author == "AutoModerator" { continue }
            if opts.minComments > 0 && post.numComments < opts.minComments { continue }
            if result.count >= limit { break }

            let isCrossPost = post.crosspostParentList?.isEmpty == false
            result.append(try await buildArticle(from: original, isCrossPost: isCrossPost, client: client))
        }
        return result
```

Add the extracted builder (place it right after `aggregate()`), containing the exact logic that previously lived inline:

```swift
    /// Build one article from a (possibly crosspost-resolved) Reddit post. Shared by `aggregate()`
    /// and `refetch`.
    private func buildArticle(from post: RedditPostData, isCrossPost: Bool,
                              client: RedditClient) async throws -> AggregatedArticle {
        let date = Date(timeIntervalSince1970: post.createdUTC)
        let permalink = "https://reddit.com\(RedditMarkdown.decodeEntities(post.permalink))"
        var body = try await buildContent(post: post, isCrossPost: isCrossPost, client: client)
        let headerURL = await headerImageURL(for: post)
        if let headerURL { body = stripImage(from: body, url: headerURL) }
        var headerHTML: String?
        if options.includeHeaderImage, let headerURL {
            headerHTML = try await makeHeaderHTML(headerURL, title: post.title)
        }
        let content = ContentFormatter.format(content: body, title: post.title, url: permalink,
                                              headerHTML: headerHTML, commentsHTML: nil)
        return AggregatedArticle(
            title: post.title, identifier: permalink, url: permalink,
            rawContent: body, content: content,
            date: date, author: post.author, iconURL: nil)
    }

    func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? {
        guard let postID = Self.postID(fromPermalink: seed.identifier) else { return nil }
        let client = try await makeClient()
        guard let post = try await client.fetchPost(subreddit: normalizedSubreddit, postID: postID) else { return nil }
        let isCrossPost = post.crosspostParentList?.isEmpty == false
        let original = post.crosspostParentList?.first ?? post
        return try await buildArticle(from: original, isCrossPost: isCrossPost, client: client)
    }

    /// Extract the base-36 post ID from a permalink like `…/r/<sub>/comments/<id>/<slug>/`.
    static func postID(fromPermalink permalink: String) -> String? {
        guard let r = permalink.range(of: #"/comments/([a-zA-Z0-9]+)"#, options: .regularExpression) else { return nil }
        return permalink[r].replacingOccurrences(of: "/comments/", with: "")
    }
```

Note: `aggregate()` previously read `post.author` for the AutoModerator filter using the *outer* `post`; keep that filter on the outer `post` as shown in Step 3's loop (unchanged from the original). `buildArticle` uses the crosspost-resolved `original`, matching the original inline logic.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditAggregatorTests 2>&1 | tail -30`
Expected: PASS (new refetch tests AND the pre-existing `aggregate()` tests, proving the extraction preserved behavior).

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditAggregator.swift YanaTests/RedditAggregatorTests.swift
git commit -m "feat(reader): Reddit refetch rebuilds a single post"
```

---

### Task 5: Remove feed-reload fallbacks from forceReload(article:)

**Files:**
- Modify: `Yana/Services/AggregationService.swift:227-262` (`forceReload(article:)`)
- Test: `YanaTests/AggregationServiceTests.swift` (replace the fallback test; add a no-aggregator test)

**Interfaces:**
- Consumes: existing `makeAggregator`, `currentAIProcessor()`, `ArticleUpsert.apply(...)`, `starredTag()`, `now()`; `Aggregator.refetch(_:)` (Tasks 1, 2, 4).
- Produces: `forceReload(article:)` returns 0 (no feed reload) when the aggregator can't be built or `refetch` yields `nil`; otherwise upserts only the refreshed article. (Signature unchanged: `@discardableResult func forceReload(article: Article) async -> Int`.)

- [ ] **Step 1: Update the tests**

In `YanaTests/AggregationServiceTests.swift`, **replace** `forceReloadArticleFallsBackToFeedWhenRefetchUnsupported` (lines 452-472) with a test asserting NO feed reload happens when `refetch` returns nil (`RefetchFakeAggregator` already exists in this file):

```swift
@Test func forceReloadArticleDoesNotReloadFeedWhenRefetchReturnsNil() async throws {
    let context = try makeContext()
    let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
    context.insert(feed)
    let article = Article(title: "Old", identifier: "id1", url: "https://x/1",
                          rawContent: "", content: "OLD", date: .now, author: "", iconURL: nil)
    article.feed = feed
    context.insert(article)

    // refetch returns nil, and the aggregator also offers a feed article — which must NOT be imported.
    var feedOnly = self.aggregated("id1"); feedOnly.content = "FROM_FEED"
    let feedArticle = feedOnly
    let service = AggregationService(context: context, makeAggregator: { _, _ in
        RefetchFakeAggregator(articles: [feedArticle], refetchResult: nil)
    }, aiProcessor: FakeAIProcessor())
    let inserted = await service.forceReload(article: article)

    #expect(inserted == 0)                       // nothing reloaded
    #expect(article.content == "OLD")            // current article untouched (no feed reload)
    #expect(feed.articles.count == 1)            // no extra articles imported
}

@Test func forceReloadArticleReturnsZeroWhenAggregatorUnavailable() async throws {
    let context = try makeContext()
    let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
    context.insert(feed)
    let article = Article(title: "Old", identifier: "id1", url: "https://x/1",
                          rawContent: "", content: "OLD", date: .now, author: "", iconURL: nil)
    article.feed = feed
    context.insert(article)

    let service = AggregationService(context: context, makeAggregator: { _, _ in nil },
                                     aiProcessor: FakeAIProcessor())
    let inserted = await service.forceReload(article: article)

    #expect(inserted == 0)
    #expect(article.content == "OLD")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationServiceTests 2>&1 | tail -30`
Expected: `forceReloadArticleDoesNotReloadFeedWhenRefetchReturnsNil` FAILS (`article.content` becomes `FROM_FEED` via the current fallback; `inserted == 1`).

- [ ] **Step 3: Remove the fallbacks**

In `Yana/Services/AggregationService.swift`, in `forceReload(article:)`:

Replace the no-aggregator fallback (around line 236):

```swift
        guard let aggregator = makeAggregator(config, credentials) else {
            return await forceReload(feed: feed)
        }
```

with:

```swift
        guard let aggregator = makeAggregator(config, credentials) else { return 0 }
```

And replace the nil-refetch fallback (around line 254):

```swift
        guard let refreshed else {
            return await forceReload(feed: feed)
        }
```

with:

```swift
        guard let refreshed else { return 0 }
```

Leave the rest of the method (seed construction, `currentAIProcessor().process`, `ArticleUpsert.apply`, `context.save`) unchanged. Also update the method's doc comment (lines ~223-226) to drop the "falls back to a forced reload of the parent feed" sentence — replace it with: "Returns 0 when the source can't re-fetch the lone item (the article is left untouched); never reloads the parent feed."

- [ ] **Step 4: Run the full suite to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -30`
Expected: PASS (entire suite — confirms no other test relied on the removed fallback).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/AggregationServiceTests.swift
git commit -m "feat(reader): Reload never falls back to a full feed reload"
```

---

### Task 6: Update documentation

**Files:**
- Modify: `CLAUDE.md` (the "Update vs. reload" bullet describing `forceReload(article:)`)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the reload description**

In `CLAUDE.md`, find the "Update vs. reload" bullet. It currently says the reader overflow menu's "Reload" calls `forceReload(article:)` "(current article only — falls back to `forceReload(feed:)` when the source can't re-fetch a lone item)". Replace that parenthetical with: "(current article only — every aggregator now re-fetches a single item: website/scrapers re-scrape the page, RSS/podcast pick the matching feed entry, YouTube/Reddit fetch the one video/post; if the item is gone it leaves the article untouched and never reloads the feed)". Keep the Feeds-swipe "Reload" → `forceReload(feed:)` description unchanged.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: Reader Reload is single-article-only for every source"
```

---

## Self-Review

**Spec coverage:**
- RSS/podcast single-entry refetch → Task 1 ✅
- YouTube single-video refetch → Task 2 ✅
- Reddit single-post refetch (incl. new `RedditClient.fetchPost`) → Tasks 3 + 4 ✅
- `forceReload(article:)` drops both feed fallbacks → Task 5 ✅
- Out-of-scope items (feed-swipe Reload, Update semantics) → untouched ✅
- Testing section bullets → covered by tests in Tasks 1-5 ✅
- Docs drift (CLAUDE.md describes the old fallback) → Task 6 ✅

**Placeholder scan:** No TBD/TODO; every code step shows complete code and exact commands.

**Type consistency:**
- `refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle?` matches the protocol in `Aggregator.swift` across Tasks 1, 2, 4.
- `RedditClient.fetchPost(subreddit:postID:) -> RedditPostData?` defined in Task 3, consumed in Task 4 with matching argument labels.
- `buildArticle(from:isCrossPost:client:)` and `postID(fromPermalink:)` are both defined and consumed within Task 4.
- `RefetchFakeAggregator(articles:refetchResult:)`, `FakeAIProcessor`, `aggregated(_:)`, `makeContext()` are pre-existing test helpers in `AggregationServiceTests.swift`.
