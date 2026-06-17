# Feed Logos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every feed a logo — shown in the feed list and integrated into the top-right of each article's title — sourced from the Reddit/YouTube APIs, hardcoded brand sites, or the feed's own favicon, and cached locally.

**Architecture:** A new `Feed.logoHash` stores the content hash of a cached logo image (served via the existing `yana-img://` scheme). A `FeedLogoResolver` picks one of three source URLs — an API image (`Aggregator.logoImageURL()`, overridden by Reddit/YouTube), a hardcoded `AggregatorType.brandSiteURL` favicon, or the feed-identifier favicon (`FaviconResolver`). `AggregationService` resolves+caches it lazily during updates when `logoHash == nil`. The feed list renders `FeedLogoView`; the article header injects a floated `<img>`.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, SwiftData, Swift Testing (`import Testing`), SwiftSoup (HTML parsing), ImageIO (`ImageCompressor`), the existing `ImageStore`/`HTTPClient`/`RedditClient`/`YouTubeClient`.

## Global Constraints

- **Platform:** iOS 26.0+; Swift 6 strict concurrency with `@MainActor` where the codebase already uses it.
- **Privacy:** logo images are only ever fetched from the feed's/brand's own domain or the Reddit/YouTube APIs the app is authorized for. **No third-party favicon services.** No remote image URLs reach the WebView — logos are served through `yana-img://<hash>` only.
- **Best-effort:** logo resolution must never block or fail a feed update; a failure leaves `logoHash == nil` and is retried next run.
- **No bundled binary assets** for logos.
- **Reuse** `ImageStore` (download/compress/hash-cache), `ImageSchemeHandler`, `HTTPClient.fetchData`, `RedditMarkdown.decodeEntities`.
- **Translations:** every new user-facing string MUST be added to `Yana/Resources/Localizable.xcstrings` with a `de` translation marked `"state" : "translated"` (Apple style, infinitive, no "Du"/"Sie").
- **New source files** under `Yana/` and `YanaTests/` require running `xcodegen generate` before building.
- **Test command:** `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`

---

### Task 1: Add `Feed.logoHash`

**Files:**
- Modify: `Yana/Models/Feed.swift`
- Test: `YanaTests/FeedLogoModelTests.swift`

**Interfaces:**
- Produces: `Feed.logoHash: String?` (defaults to `nil`).

- [ ] **Step 1: Write the failing test**

Create `YanaTests/FeedLogoModelTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Feed.logoHash")
struct FeedLogoModelTests {
    @Test func defaultsToNilAndIsSettable() {
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://e.com/f.xml")
        #expect(feed.logoHash == nil)
        feed.logoHash = "abc123"
        #expect(feed.logoHash == "abc123")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test` (after `xcodegen generate`)
Expected: COMPILE FAILURE — `value of type 'Feed' has no member 'logoHash'`.

- [ ] **Step 3: Add the property**

In `Yana/Models/Feed.swift`, after the `var lastError: String?` line (currently line 14), add:

```swift
    /// Content hash of the feed's cached logo image (served via `yana-img://`), or nil until resolved.
    var logoHash: String?
```

(No change to `init` — the optional defaults to `nil`. SwiftData treats the added optional as an additive, no-op migration.)

- [ ] **Step 4: Regenerate project and run the test**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/Feed.swift YanaTests/FeedLogoModelTests.swift
git commit -m "feat(feed): add logoHash field"
```

---

### Task 2: `AggregatorType.brandSiteURL`

**Files:**
- Modify: `Yana/Aggregators/AggregatorType.swift`
- Test: `YanaTests/AggregatorTypeLogoTests.swift`

**Interfaces:**
- Produces: `AggregatorType.brandSiteURL: String?` — hardcoded home page for fixed-brand scrapers, `nil` for all other types.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregatorTypeLogoTests.swift`:

```swift
import Testing
@testable import Yana

@Suite("AggregatorType.brandSiteURL")
struct AggregatorTypeLogoTests {
    @Test func fixedBrandTypesHaveSiteURLs() {
        #expect(AggregatorType.heise.brandSiteURL == "https://www.heise.de/")
        #expect(AggregatorType.merkur.brandSiteURL == "https://www.merkur.de/")
        #expect(AggregatorType.tagesschau.brandSiteURL == "https://www.tagesschau.de/")
        #expect(AggregatorType.explosm.brandSiteURL == "https://explosm.net/")
        #expect(AggregatorType.darkLegacy.brandSiteURL == "https://darklegacycomics.com/")
        #expect(AggregatorType.caschysBlog.brandSiteURL == "https://stadt-bremerhaven.de/")
        #expect(AggregatorType.mactechnews.brandSiteURL == "https://www.mactechnews.de/")
        #expect(AggregatorType.oglaf.brandSiteURL == "https://www.oglaf.com/")
        #expect(AggregatorType.meinMmo.brandSiteURL == "https://mein-mmo.de/")
    }

    @Test func nonBrandTypesHaveNoSiteURL() {
        for type in [AggregatorType.fullWebsite, .feedContent, .youtube, .reddit, .podcast] {
            #expect(type.brandSiteURL == nil)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: COMPILE FAILURE — no member `brandSiteURL`.

- [ ] **Step 3: Add the property**

In `Yana/Aggregators/AggregatorType.swift`, add after the `displayName` computed property (after line 54):

```swift
    /// Hardcoded brand home page whose favicon is used as the feed logo, for fixed-brand
    /// scrapers. `nil` for URL-based types (favicon comes from the feed identifier) and for
    /// reddit/youtube (logo comes from their API).
    var brandSiteURL: String? {
        switch self {
        case .heise: "https://www.heise.de/"
        case .merkur: "https://www.merkur.de/"
        case .tagesschau: "https://www.tagesschau.de/"
        case .explosm: "https://explosm.net/"
        case .darkLegacy: "https://darklegacycomics.com/"
        case .caschysBlog: "https://stadt-bremerhaven.de/"
        case .mactechnews: "https://www.mactechnews.de/"
        case .oglaf: "https://www.oglaf.com/"
        case .meinMmo: "https://mein-mmo.de/"
        case .fullWebsite, .feedContent, .youtube, .reddit, .podcast: nil
        }
    }
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/AggregatorType.swift YanaTests/AggregatorTypeLogoTests.swift
git commit -m "feat(aggregator): add brandSiteURL for fixed-brand logos"
```

---

### Task 3: `FaviconResolver` HTML parsing (pure)

**Files:**
- Create: `Yana/Aggregators/Utils/FaviconResolver.swift`
- Test: `YanaTests/FaviconResolverTests.swift`

**Interfaces:**
- Produces: `FaviconResolver.bestIconURL(fromHTML: String, baseURL: URL) -> String?` — selects the best icon `<link>` from page HTML, resolving relative hrefs; `nil` when no icon link is present.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/FaviconResolverTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("FaviconResolver parsing")
struct FaviconResolverTests {
    private let base = URL(string: "https://example.com/blog/")!

    @Test func prefersAppleTouchIcon() {
        let html = """
        <html><head>
          <link rel="icon" sizes="32x32" href="/favicon-32.png">
          <link rel="apple-touch-icon" href="/touch.png">
        </head></html>
        """
        #expect(FaviconResolver.bestIconURL(fromHTML: html, baseURL: base) == "https://example.com/touch.png")
    }

    @Test func prefersLargestSizeAmongIcons() {
        let html = """
        <html><head>
          <link rel="icon" sizes="16x16" href="/small.png">
          <link rel="icon" sizes="180x180" href="/big.png">
        </head></html>
        """
        #expect(FaviconResolver.bestIconURL(fromHTML: html, baseURL: base) == "https://example.com/big.png")
    }

    @Test func resolvesRelativeHrefAgainstBase() {
        let html = #"<html><head><link rel="shortcut icon" href="icon.ico"></head></html>"#
        #expect(FaviconResolver.bestIconURL(fromHTML: html, baseURL: base) == "https://example.com/blog/icon.ico")
    }

    @Test func returnsNilWhenNoIconLink() {
        let html = "<html><head><title>No icons</title></head></html>"
        #expect(FaviconResolver.bestIconURL(fromHTML: html, baseURL: base) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: COMPILE FAILURE — no type `FaviconResolver`.

- [ ] **Step 3: Implement the parser**

Create `Yana/Aggregators/Utils/FaviconResolver.swift`:

```swift
import Foundation
import SwiftSoup

/// Finds a site's best icon by parsing its HTML `<link rel>` tags (apple-touch-icon preferred,
/// then largest declared size), with a `/favicon.ico` network fallback. Only ever contacts the
/// site's own domain — no third-party favicon services.
enum FaviconResolver {
    /// Pure selection from parsed HTML. Returns the absolute URL of the best icon link, or nil
    /// when the page declares no icon link (caller then tries `/favicon.ico`).
    static func bestIconURL(fromHTML html: String, baseURL: URL) -> String? {
        guard let doc = try? SwiftSoup.parse(html, baseURL.absoluteString),
              let links = try? doc.select("link[rel]") else { return nil }

        struct Candidate { let href: String; let isAppleTouch: Bool; let area: Int }
        var candidates: [Candidate] = []
        for link in links.array() {
            let rel = ((try? link.attr("rel")) ?? "").lowercased()
            let tokens = rel.split(whereSeparator: { $0 == " " }).map(String.init)
            let isAppleTouch = rel.contains("apple-touch-icon")
            let isIcon = isAppleTouch || tokens.contains("icon")
            guard isIcon else { continue }
            let href = (try? link.attr("href")) ?? ""
            guard !href.isEmpty else { continue }
            let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL.absoluteString ?? href
            candidates.append(Candidate(href: resolved, isAppleTouch: isAppleTouch,
                                        area: sizeArea((try? link.attr("sizes")) ?? "")))
        }
        guard !candidates.isEmpty else { return nil }
        // apple-touch-icon wins; otherwise the largest declared size.
        let best = candidates.max { a, b in
            if a.isAppleTouch != b.isAppleTouch { return !a.isAppleTouch && b.isAppleTouch }
            return a.area < b.area
        }
        return best?.href
    }

    /// Parses the first WxH from a `sizes` attribute (e.g. "180x180" -> 32400). 0 when absent.
    private static func sizeArea(_ sizes: String) -> Int {
        let parts = sizes.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return 0 }
        return w * h
    }
}
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/FaviconResolver.swift YanaTests/FaviconResolverTests.swift
git commit -m "feat(favicon): parse best icon link from site HTML"
```

---

### Task 4: `FaviconResolver` network wrapper + `/favicon.ico` fallback

**Files:**
- Modify: `Yana/Aggregators/Utils/FaviconResolver.swift`
- Test: `YanaTests/FaviconResolverTests.swift`

**Interfaces:**
- Produces: `FaviconResolver.bestIconURL(forSite: String, fetch: @Sendable (URL) async throws -> (Data, String?)) async -> String?` — fetches the site HTML, returns the parsed best icon, else `<origin>/favicon.ico`, else `nil`. `fetch` defaults to `HTTPClient.fetchData`.

- [ ] **Step 1: Write the failing test**

Append to `YanaTests/FaviconResolverTests.swift` (inside the suite):

```swift
    @Test func networkUsesParsedIconWhenPresent() async {
        let html = #"<html><head><link rel="apple-touch-icon" href="/touch.png"></head></html>"#
        let icon = await FaviconResolver.bestIconURL(forSite: "https://example.com/") { _ in
            (Data(html.utf8), "text/html")
        }
        #expect(icon == "https://example.com/touch.png")
    }

    @Test func networkFallsBackToFaviconIco() async {
        let html = "<html><head><title>No icons</title></head></html>"
        let icon = await FaviconResolver.bestIconURL(forSite: "https://example.com/path/") { _ in
            (Data(html.utf8), "text/html")
        }
        #expect(icon == "https://example.com/favicon.ico")
    }

    @Test func networkReturnsNilWhenFetchThrows() async {
        struct Boom: Error {}
        let icon = await FaviconResolver.bestIconURL(forSite: "https://example.com/") { _ in throw Boom() }
        #expect(icon == nil)
    }
}
```

Note: remove the closing `}` from the previous test file's final brace and add it after these tests (these methods live inside the existing `struct FaviconResolverTests`).

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: COMPILE FAILURE — no `bestIconURL(forSite:fetch:)`.

- [ ] **Step 3: Add the network wrapper**

In `Yana/Aggregators/Utils/FaviconResolver.swift`, add inside the `enum FaviconResolver` (above the private `sizeArea`):

```swift
    /// Resolve the best icon URL for a site: fetch its HTML, parse icon links, else fall back to
    /// `<origin>/favicon.ico`. Returns nil only when the site URL is unusable or the fetch fails.
    static func bestIconURL(
        forSite siteURL: String,
        fetch: @Sendable (URL) async throws -> (Data, String?) = { try await HTTPClient.fetchData($0) }
    ) async -> String? {
        guard let url = URL(string: siteURL),
              let scheme = url.scheme, let host = url.host else { return nil }
        guard let (data, _) = try? await fetch(url),
              let html = String(data: data, encoding: .utf8) else { return nil }
        if let parsed = bestIconURL(fromHTML: html, baseURL: url) { return parsed }
        return "\(scheme)://\(host)/favicon.ico"
    }
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/FaviconResolver.swift YanaTests/FaviconResolverTests.swift
git commit -m "feat(favicon): network resolution with favicon.ico fallback"
```

---

### Task 5: `Aggregator.logoImageURL()` default

**Files:**
- Modify: `Yana/Aggregators/Aggregator.swift`
- Test: `YanaTests/AggregatorLogoDefaultTests.swift`

**Interfaces:**
- Produces: `Aggregator.logoImageURL() async -> String?` with a default implementation returning `nil`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregatorLogoDefaultTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("Aggregator.logoImageURL default")
struct AggregatorLogoDefaultTests {
    private struct PlainAggregator: Aggregator {
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { [] }
    }

    @Test func defaultsToNil() async {
        let value = await PlainAggregator().logoImageURL()
        #expect(value == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: COMPILE FAILURE — no member `logoImageURL`.

- [ ] **Step 3: Add the protocol method + default**

In `Yana/Aggregators/Aggregator.swift`, add a declaration to the `protocol Aggregator` (after the `refetch` requirement, line 35):

```swift
    /// Remote URL of this feed's logo image when the aggregator can source one directly (e.g.
    /// from its API). `nil` means "derive the logo from the site favicon instead".
    func logoImageURL() async -> String?
```

And add a default in the `extension Aggregator` block (after the `refetch` default, line 39):

```swift
    func logoImageURL() async -> String? { nil }
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Aggregator.swift YanaTests/AggregatorLogoDefaultTests.swift
git commit -m "feat(aggregator): add logoImageURL() with nil default"
```

---

### Task 6: `RedditClient.fetchSubredditAbout`

**Files:**
- Modify: `Yana/Aggregators/Concrete/RedditClient.swift`
- Test: `YanaTests/RedditClientAboutTests.swift`

**Interfaces:**
- Consumes: `RedditMarkdown.decodeEntities(_:)`.
- Produces: `RedditClient.fetchSubredditAbout(_ subreddit: String) async -> String?` — returns the subreddit's `community_icon` (preferred) or `icon_img`, entity-decoded and trimmed; `nil` when both are empty or the request fails.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/RedditClientAboutTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("RedditClient.fetchSubredditAbout")
struct RedditClientAboutTests {
    private let token = #"{"access_token":"T"}"#

    private func client(aboutJSON: String) -> RedditClient {
        RedditClient(clientID: "id", clientSecret: "s", userAgent: "Yana/1.0") { req in
            req.url!.absoluteString.contains("access_token")
                ? Data(self.token.utf8) : Data(aboutJSON.utf8)
        }
    }

    @Test func prefersCommunityIcon() async {
        let c = client(aboutJSON: #"{"data":{"community_icon":"https://r/ci.png?w=256","icon_img":"https://r/i.png"}}"#)
        #expect(await c.fetchSubredditAbout("swift") == "https://r/ci.png?w=256")
    }

    @Test func fallsBackToIconImg() async {
        let c = client(aboutJSON: #"{"data":{"community_icon":"","icon_img":"https://r/i.png"}}"#)
        #expect(await c.fetchSubredditAbout("swift") == "https://r/i.png")
    }

    @Test func decodesHTMLEntities() async {
        let c = client(aboutJSON: #"{"data":{"community_icon":"https://r/ci.png?a=1&amp;b=2"}}"#)
        #expect(await c.fetchSubredditAbout("swift") == "https://r/ci.png?a=1&b=2")
    }

    @Test func nilWhenBothEmpty() async {
        let c = client(aboutJSON: #"{"data":{"community_icon":"","icon_img":""}}"#)
        #expect(await c.fetchSubredditAbout("swift") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: COMPILE FAILURE — no member `fetchSubredditAbout`.

- [ ] **Step 3: Implement the method + decoding struct**

In `Yana/Aggregators/Concrete/RedditClient.swift`, add this method to `final class RedditClient` (after `fetchComments`, around line 88):

```swift
    /// Subreddit icon for the feed logo. Prefers `community_icon`, falls back to `icon_img`.
    /// Returns the entity-decoded, trimmed URL, or nil when unavailable.
    func fetchSubredditAbout(_ subreddit: String) async -> String? {
        guard let url = URL(string:
            "https://oauth.reddit.com/r/\(Self.encodePath(subreddit))/about.json?raw_json=1")
        else { return nil }
        guard let data = try? await authorizedGET(url),
              let about = try? JSONDecoder().decode(RedditAboutResponse.self, from: data) else { return nil }
        for raw in [about.data.communityIcon, about.data.iconImg] {
            guard let raw, !raw.isEmpty else { continue }
            let decoded = RedditMarkdown.decodeEntities(raw).trimmingCharacters(in: .whitespaces)
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }
```

Add the decoding envelope alongside the other `private struct` envelopes at the bottom of the file (after `RedditSubredditListing`, around line 159):

```swift
private struct RedditAboutResponse: Decodable {
    let data: AboutData
    struct AboutData: Decodable {
        let communityIcon: String?
        let iconImg: String?
        enum CodingKeys: String, CodingKey {
            case communityIcon = "community_icon", iconImg = "icon_img"
        }
    }
}
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditClient.swift YanaTests/RedditClientAboutTests.swift
git commit -m "feat(reddit): fetch subreddit icon via about.json"
```

---

### Task 7: `RedditAggregator.logoImageURL()`

**Files:**
- Modify: `Yana/Aggregators/Concrete/RedditAggregator.swift`
- Test: `YanaTests/RedditAggregatorTests.swift`

**Interfaces:**
- Consumes: `RedditClient.fetchSubredditAbout(_:)`, the aggregator's private `makeClient()` and `normalizedSubreddit`.
- Produces: `RedditAggregator.logoImageURL() async -> String?`.

- [ ] **Step 1: Write the failing test**

Append to the `RedditAggregatorTests` suite in `YanaTests/RedditAggregatorTests.swift` (inside the struct, before its closing brace):

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL / COMPILE FAILURE — `logoImageURL` not overridden (uses nil default, first test fails).

- [ ] **Step 3: Add the override**

In `Yana/Aggregators/Concrete/RedditAggregator.swift`, add to `final class RedditAggregator` (after `aggregate()`, before the "Content building" MARK, around line 72):

```swift
    func logoImageURL() async -> String? {
        guard let client = try? await makeClient() else { return nil }
        return await client.fetchSubredditAbout(normalizedSubreddit)
    }
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditAggregator.swift YanaTests/RedditAggregatorTests.swift
git commit -m "feat(reddit): expose subreddit icon as logoImageURL"
```

---

### Task 8: `YouTubeAggregator.logoImageURL()`

**Files:**
- Modify: `Yana/Aggregators/Concrete/YouTubeAggregator.swift`
- Test: `YanaTests/YouTubeAggregatorTests.swift`

**Interfaces:**
- Consumes: `YouTubeClient.resolveChannelID(_:)`, `YouTubeClient.fetchChannelData(_:)` (`.iconURL`), the aggregator's private `makeClient()`.
- Produces: `YouTubeAggregator.logoImageURL() async -> String?`.

- [ ] **Step 1: Write the failing test**

Append to the `YouTubeAggregatorTests` suite in `YanaTests/YouTubeAggregatorTests.swift` (inside the struct, before its closing brace):

```swift
    @Test func logoImageURLReturnsChannelIcon() async {
        // makeAggregator's fixture returns channelsJSON with snippet.thumbnails.high = https://img/c.jpg
        #expect(await makeAggregator(key: "K").logoImageURL() == "https://img/c.jpg")
    }

    @Test func logoImageURLNilWithoutKey() async {
        #expect(await makeAggregator(key: nil).logoImageURL() == nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `logoImageURL` returns nil default (first test fails).

- [ ] **Step 3: Add the override**

In `Yana/Aggregators/Concrete/YouTubeAggregator.swift`, add to `final class YouTubeAggregator` (after `aggregate()`, before the "Content building" MARK, around line 60):

```swift
    func logoImageURL() async -> String? {
        guard let client = try? makeClient() else { return nil }
        guard let channelID = try? await client.resolveChannelID(config.identifier),
              let channel = try? await client.fetchChannelData(channelID) else { return nil }
        return channel.iconURL
    }
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/YouTubeAggregator.swift YanaTests/YouTubeAggregatorTests.swift
git commit -m "feat(youtube): expose channel icon as logoImageURL"
```

---

### Task 9: `FeedLogoResolver` (source-URL selection)

**Files:**
- Create: `Yana/Aggregators/FeedLogoResolver.swift`
- Test: `YanaTests/FeedLogoResolverTests.swift`

**Interfaces:**
- Consumes: `Aggregator.logoImageURL()`, `AggregatorType.brandSiteURL`, `FaviconResolver.bestIconURL(forSite:)`.
- Produces:
  - `FeedLogoResolver.logoImageURL(for: FeedConfig, aggregator: (any Aggregator)?, faviconResolver: (String) async -> String?) async -> String?`
  - `FeedLogoResolver.siteOrigin(of: String) -> String?`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/FeedLogoResolverTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("FeedLogoResolver")
struct FeedLogoResolverTests {
    private struct FakeAggregator: Aggregator {
        var logo: String?
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { [] }
        func logoImageURL() async -> String? { logo }
    }

    private func config(_ type: AggregatorType, _ identifier: String) -> FeedConfig {
        FeedConfig(type: type, identifier: identifier, dailyLimit: 10,
                   options: type.defaultOptions, collectedToday: 0)
    }

    @Test func usesAPIImageWhenAggregatorProvidesOne() async {
        var faviconCalled = false
        let result = await FeedLogoResolver.logoImageURL(
            for: config(.reddit, "swift"),
            aggregator: FakeAggregator(logo: "https://api/icon.png"),
            faviconResolver: { _ in faviconCalled = true; return "https://should/not.png" })
        #expect(result == "https://api/icon.png")
        #expect(faviconCalled == false)
    }

    @Test func usesBrandSiteFaviconForFixedBrands() async {
        var capturedSite: String?
        let result = await FeedLogoResolver.logoImageURL(
            for: config(.heise, ""),
            aggregator: FakeAggregator(logo: nil),
            faviconResolver: { site in capturedSite = site; return "https://www.heise.de/favicon.ico" })
        #expect(capturedSite == "https://www.heise.de/")
        #expect(result == "https://www.heise.de/favicon.ico")
    }

    @Test func usesIdentifierOriginForURLBasedFeeds() async {
        var capturedSite: String?
        let result = await FeedLogoResolver.logoImageURL(
            for: config(.feedContent, "https://blog.example.com/feed.xml"),
            aggregator: FakeAggregator(logo: nil),
            faviconResolver: { site in capturedSite = site; return "\(site)favicon.ico" })
        #expect(capturedSite == "https://blog.example.com/")
        #expect(result == "https://blog.example.com/favicon.ico")
    }

    @Test func siteOriginExtractsSchemeAndHost() {
        #expect(FeedLogoResolver.siteOrigin(of: "https://a.b.com/x/y?q=1") == "https://a.b.com/")
        #expect(FeedLogoResolver.siteOrigin(of: "not-a-url") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: COMPILE FAILURE — no type `FeedLogoResolver`.

- [ ] **Step 3: Implement the resolver**

Create `Yana/Aggregators/FeedLogoResolver.swift`:

```swift
import Foundation

/// Chooses the remote logo image URL for a feed, in priority order:
/// 1. an API image the aggregator provides (reddit/youtube),
/// 2. the hardcoded brand-site favicon (fixed-brand scrapers),
/// 3. the feed identifier's site favicon (url-based feeds).
/// Returns the URL only; caching is the caller's job.
enum FeedLogoResolver {
    static func logoImageURL(
        for config: FeedConfig,
        aggregator: (any Aggregator)?,
        faviconResolver: (String) async -> String? = { await FaviconResolver.bestIconURL(forSite: $0) }
    ) async -> String? {
        if let api = await aggregator?.logoImageURL(), !api.isEmpty { return api }
        if let brand = config.type.brandSiteURL { return await faviconResolver(brand) }
        if let origin = siteOrigin(of: config.identifier) { return await faviconResolver(origin) }
        return nil
    }

    /// `scheme://host/` for a URL identifier, or nil when the identifier isn't an absolute URL.
    static func siteOrigin(of identifier: String) -> String? {
        guard let comps = URLComponents(string: identifier),
              let scheme = comps.scheme, let host = comps.host else { return nil }
        return "\(scheme)://\(host)/"
    }
}
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/FeedLogoResolver.swift YanaTests/FeedLogoResolverTests.swift
git commit -m "feat(logo): FeedLogoResolver source-URL selection"
```

---

### Task 10: Resolve + cache logos in `AggregationService`

**Files:**
- Modify: `Yana/Services/AggregationService.swift`
- Test: `YanaTests/AggregationServiceTests.swift`

**Interfaces:**
- Consumes: `FeedLogoResolver.logoImageURL(for:aggregator:)`, `ImageStore.shared.store(remoteURL:isHeader:)`, `Feed.logoHash`.
- Produces: an injectable `AggregationService` logo seam: `init(..., logoResolver: @escaping LogoResolver = AggregationService.defaultLogoResolver)` where `typealias LogoResolver = @Sendable (FeedConfig, any Aggregator) async -> String?`. The service writes `feed.logoHash` on a successful run when it was `nil`.

- [ ] **Step 1: Write the failing test**

Append to the `AggregationServiceTests` suite in `YanaTests/AggregationServiceTests.swift` (inside the struct):

```swift
    @Test func setsLogoHashWhenMissing() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://e.com/f.xml")
        context.insert(feed)

        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
            logoResolver: { _, _ in "cafef00d" })
        await service.update(feed: feed)

        #expect(feed.logoHash == "cafef00d")
    }

    @Test func doesNotReResolveLogoWhenAlreadySet() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://e.com/f.xml")
        feed.logoHash = "existing"
        context.insert(feed)

        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
            logoResolver: { _, _ in "newvalue" })
        await service.update(feed: feed)

        #expect(feed.logoHash == "existing")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: COMPILE FAILURE — `AggregationService` init has no `logoResolver:` parameter.

- [ ] **Step 3: Add the seam and call site**

In `Yana/Services/AggregationService.swift`:

(a) Add the typealias and default just inside the class, after the `maxConcurrentFeedUpdates` constant (around line 24):

```swift
    /// Resolves and caches a feed's logo, returning its content hash. Injectable for tests.
    typealias LogoResolver = @Sendable (_ config: FeedConfig, _ aggregator: any Aggregator) async -> String?

    /// Default logo resolver: pick a source URL (API image / brand favicon / identifier favicon)
    /// then download + compress + cache via the shared image store.
    static let defaultLogoResolver: LogoResolver = { config, aggregator in
        guard let urlString = await FeedLogoResolver.logoImageURL(for: config, aggregator: aggregator),
              let url = URL(string: urlString) else { return nil }
        return await ImageStore.shared.store(remoteURL: url, isHeader: false)
    }
```

(b) Add a stored property next to the other `private let`s (after `private let now: () -> Date`, around line 30):

```swift
    private let logoResolver: LogoResolver
```

(c) Add the parameter to `init` (extend the existing signature) and assign it:

```swift
    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        aiProcessor: AIProcessing? = nil,
        now: @escaping () -> Date = { .now },
        logoResolver: @escaping LogoResolver = AggregationService.defaultLogoResolver
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        self.injectedAIProcessor = aiProcessor
        self.now = now
        self.logoResolver = logoResolver
    }
```

(d) In `aggregate(feed:force:)`, in the success branch, insert logo resolution after `feed.lastError = nil` and before `return inserted`:

```swift
            feed.lastFetchedAt = runNow
            feed.lastError = nil
            if feed.logoHash == nil, let hash = await logoResolver(config, aggregator) {
                feed.logoHash = hash
            }
            return inserted
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS (both new tests; existing tests unaffected — `FakeAggregator` uses the nil `logoImageURL` default and the default resolver isn't reached because tests inject one or hit no logoless path).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/AggregationServiceTests.swift
git commit -m "feat(aggregation): resolve and cache feed logos on update"
```

---

### Task 11: `FeedLogoView` + feed-list integration

**Files:**
- Create: `Yana/Views/Config/FeedLogoView.swift`
- Modify: `Yana/Views/Config/FeedsView.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`
- Test: `YanaTests/FeedLogoViewTests.swift`

**Interfaces:**
- Consumes: `ImageStore.shared.fileURL(forHash:)`, `Feed.logoHash`.
- Produces:
  - `FeedLogo.image(forHash: String?, in store: ImageStore) async -> UIImage?` (testable loader)
  - `FeedLogoView(hash: String?, size: CGFloat = 28)` (SwiftUI view)

- [ ] **Step 1: Write the failing test**

Create `YanaTests/FeedLogoViewTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("FeedLogo image loading")
struct FeedLogoViewTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    @Test func loadsStoredImageByHash() async {
        let store = tempStore()
        let hash = await store.store(remoteURL: URL(string: "https://e.com/logo.png")!, isHeader: false)
        let image = await FeedLogo.image(forHash: hash, in: store)
        #expect(image != nil)
    }

    @Test func returnsNilForNilHash() async {
        let image = await FeedLogo.image(forHash: nil, in: tempStore())
        #expect(image == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: COMPILE FAILURE — no `FeedLogo`.

- [ ] **Step 3: Implement the loader + view**

Create `Yana/Views/Config/FeedLogoView.swift`:

```swift
import SwiftUI
import UIKit

/// Loads a cached logo image by content hash from an `ImageStore`. Returns nil for a nil/missing
/// hash or unreadable file. Pure async helper so it can be unit-tested without rendering.
enum FeedLogo {
    static func image(forHash hash: String?, in store: ImageStore = .shared) async -> UIImage? {
        guard let hash else { return nil }
        let url = await store.fileURL(forHash: hash)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

/// A small rounded feed logo, with a neutral placeholder when no logo is cached yet.
struct FeedLogoView: View {
    let hash: String?
    var size: CGFloat = 28

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "globe")
                    .resizable().scaledToFit().padding(4)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(Text("Feed logo"))
        .task(id: hash) { image = await FeedLogo.image(forHash: hash) }
    }
}
```

- [ ] **Step 4: Add the logo to the feed-list row**

In `Yana/Views/Config/FeedsView.swift`, change the `row(_:)` builder so the existing `VStack` is wrapped in an `HStack` led by the logo. Replace the `return VStack(alignment: .leading, spacing: 4) {` line (line 122) with:

```swift
        return HStack(spacing: 12) {
            FeedLogoView(hash: feed.logoHash)
            VStack(alignment: .leading, spacing: 4) {
```

and add one extra closing brace for the new `HStack` at the end of `row(_:)` — the method currently ends:

```swift
            if !feed.tags.isEmpty {
                Text(feed.tags.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
```

becomes:

```swift
            if !feed.tags.isEmpty {
                Text(feed.tags.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            }
        }
    }
```

(The first added `}` closes the inner `VStack`; the second closes the new `HStack`.)

- [ ] **Step 5: Add the translation**

Add the `"Feed logo"` key to `Yana/Resources/Localizable.xcstrings` with a German translation. The entry under `"strings"` must be:

```json
    "Feed logo" : {
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Feed-Logo"
          }
        }
      }
    },
```

- [ ] **Step 6: Regenerate and run tests**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS, and the project builds (verifying the `FeedsView` row braces are balanced).

- [ ] **Step 7: Commit**

```bash
git add Yana/Views/Config/FeedLogoView.swift Yana/Views/Config/FeedsView.swift Yana/Resources/Localizable.xcstrings YanaTests/FeedLogoViewTests.swift
git commit -m "feat(feeds): show feed logo in the feed list"
```

---

### Task 12: Logo in the article header

**Files:**
- Create: `Yana/Aggregators/Utils/ArticleHeaderLogo.swift`
- Modify: `Yana/Views/ArticleWebView.swift`
- Test: `YanaTests/ArticleHeaderLogoTests.swift`

**Interfaces:**
- Consumes: `ReaderWeb.imageScheme`, `Feed.logoHash`.
- Produces: `ArticleHeaderLogo.imgTag(logoHash: String?) -> String` — returns `<img class="feed-logo" …>` when a hash is present, else `""`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleHeaderLogoTests.swift`:

```swift
import Testing
@testable import Yana

@Suite("ArticleHeaderLogo.imgTag")
struct ArticleHeaderLogoTests {
    @Test func emitsImgForHash() {
        let tag = ArticleHeaderLogo.imgTag(logoHash: "abc123")
        #expect(tag.contains("class=\"feed-logo\""))
        #expect(tag.contains("\(ReaderWeb.imageScheme)://abc123"))
    }

    @Test func emptyWhenNoHash() {
        #expect(ArticleHeaderLogo.imgTag(logoHash: nil) == "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: COMPILE FAILURE — no `ArticleHeaderLogo`.

- [ ] **Step 3: Implement the helper**

Create `Yana/Aggregators/Utils/ArticleHeaderLogo.swift`:

```swift
import Foundation

/// Builds the feed-logo `<img>` for the article header. Empty string when the feed has no
/// cached logo. The image is served via the `yana-img://` scheme (no remote URL).
enum ArticleHeaderLogo {
    static func imgTag(logoHash: String?) -> String {
        guard let logoHash, !logoHash.isEmpty else { return "" }
        return "<img class=\"feed-logo\" src=\"\(ReaderWeb.imageScheme)://\(logoHash)\" alt=\"\">"
    }
}
```

- [ ] **Step 4: Wire it into the header + add CSS**

In `Yana/Views/ArticleWebView.swift`:

(a) In the `headerHTML` computed property, change the returned block (lines 215–221) so the logo floats at the top-right of the header, before the title:

```swift
        return """
        <div class="article-header">
            \(ArticleHeaderLogo.imgTag(logoHash: article.feed?.logoHash))
            <h1>\(esc(article.title))</h1>
            <div class="article-meta">\(metaHTML)</div>
            <hr>
        </div>
        """
```

(b) In the `css` string, add a `.feed-logo` rule next to the other `.article-header` rules (after the `.article-header h1 { … }` block, around line 98):

```swift
            .feed-logo {
                float: right; width: 32px; height: 32px; margin: 2px 0 6px 12px;
                border-radius: 6px; object-fit: cover;
            }
```

- [ ] **Step 5: Regenerate and run tests**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS, and the project builds.

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Utils/ArticleHeaderLogo.swift Yana/Views/ArticleWebView.swift YanaTests/ArticleHeaderLogoTests.swift
git commit -m "feat(reader): show feed logo at top-right of article title"
```

---

## Notes for the implementer

- `ImageStore.fileURL(forHash:)` is `actor`-isolated, hence the `await` in `FeedLogo.image`. The hash→extension map is seeded from disk on init, so a cross-launch lookup works without re-downloading.
- `ImageStore.store(remoteURL:isHeader:)` already downloads, compresses (ImageIO decodes ICO/PNG/JPEG), and dedupes by content hash. Logos use `isHeader: false`.
- There is no production image-orphan purge today (`ImageStore.purgeOrphans` has no caller), so logos need no cleanup integration — they behave like every other cached image.
- The `darkLegacy` brand host is `darklegacycomics.com` (no `www`); `caschysBlog` is `stadt-bremerhaven.de`. These are intentional — verified against the aggregators' feed URLs.
- Logos are intentionally **not** part of OPML round-trip; they re-resolve on the next update.
