# Phase 4c — Generic Aggregators + Pipeline Base Classes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the template-method pipeline base classes (`RSSPipelineAggregator`, `FullWebsiteAggregator`) and the two generic aggregators (`feedContent`, `fullWebsite`), then wire them into the registry so real feeds aggregate end-to-end.

**Architecture:** `RSSPipelineAggregator` ports the server's `RssAggregator` template method (`validate → fetchEntries → makeArticle → enrich → processContent → finalize`) using the 4b utilities. `FullWebsiteAggregator` overrides `enrich` to fetch the article page, extract the main content via CSS selectors, hoist a header element, download images, and rewrite embeds. The scrapers in 4d and some media aggregators in 4e subclass these. Per decision 3, even `feedContent` downloads all images. Tests inject fixtures by subclassing the aggregator's overridable fetch hooks — no live network.

**Tech Stack:** Swift 6, SwiftSoup, SwiftData, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-16-local-aggregator-phase4-design.md` (§1, §4.1).

**Depends on:** 4a (FeedConfig, Aggregator, service), 4b (HTTPClient, FeedParser, HTMLUtils, ContentFormatter, EmbedRewriter, ImageStore, rewriteImages, HeaderElementExtractor).

---

## Pipeline base-class contract (referenced by 4d, 4e)

```swift
class RSSPipelineAggregator: Aggregator, @unchecked Sendable {
    let config: FeedConfig
    let credentials: AggregatorCredentials
    let store: ImageStore
    init(config: FeedConfig, credentials: AggregatorCredentials, store: ImageStore = .shared)

    func validate() throws                                            // default: non-empty identifier
    func aggregate() async throws -> [AggregatedArticle]              // template method (override sparingly)

    // Overridable hooks (override these in subclasses, not aggregate()):
    func fetchEntries() async throws -> [FeedEntry]                  // default: fetch+parse config.identifier
    func makeArticle(from entry: FeedEntry) -> AggregatedArticle     // default mapping
    func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle  // default: processContent on RSS content
    func processContent(_ html: String, article: AggregatedArticle, headerHTML: String?) async throws -> String  // default: embeds+images+sanitize+format
    func finalize(_ articles: [AggregatedArticle]) async throws -> [AggregatedArticle]   // default: identity (AI added in 4f)

    var contentSelector: String { get }          // default ""
    var selectorsToRemove: [String] { get }       // default []
}

class FullWebsiteAggregator: RSSPipelineAggregator {
    // overrides enrich() to fetch the page, extract content, hoist header, rewrite images/embeds
    func fetchArticleHTML(_ url: String) async throws -> String   // default: HTTPClient.fetchHTML (override in tests)
    // reads options via fullWebsiteOptions (useFullContent / customContentSelector / customSelectorsToRemove)
}
```

Test/build command:

```
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

---

## Task 1: `RSSPipelineAggregator` base class

**Files:**
- Create: `Yana/Aggregators/Concrete/RSSPipelineAggregator.swift`
- Test: `YanaTests/RSSPipelineAggregatorTests.swift`

- [ ] **Step 1: Write the failing test (subclass injects entries)**

Create `YanaTests/RSSPipelineAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("RSSPipelineAggregator")
struct RSSPipelineAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50))
            .image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func config() -> FeedConfig {
        FeedConfig(type: .feedContent, identifier: "https://x.com/feed", dailyLimit: 20,
                   options: .feedContent(FeedContentOptions()), collectedToday: 0)
    }

    /// Subclass that injects canned entries instead of fetching.
    final class StubFeed: RSSPipelineAggregator, @unchecked Sendable {
        let entries: [FeedEntry]
        init(entries: [FeedEntry], config: FeedConfig, store: ImageStore) {
            self.entries = entries
            super.init(config: config, credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
    }

    @Test func mapsEntriesAndWrapsContent() async throws {
        let entry = FeedEntry(title: "Hello", link: "https://x.com/1", content: "<p>Body</p>",
                              summary: nil, entryDescription: nil, published: .now, author: "Al",
                              enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
        let agg = StubFeed(entries: [entry], config: config(), store: tempStore())
        let articles = try await agg.aggregate()
        let a = try #require(articles.first)
        #expect(a.title == "Hello")
        #expect(a.identifier == "https://x.com/1")
        #expect(a.content.contains("Body"))
        #expect(a.content.contains("article-content"))      // wrapped
        #expect(a.content.contains("Source:"))               // footer
    }

    @Test func emptyIdentifierFailsValidation() async {
        var cfg = config(); cfg.identifier = ""
        let agg = StubFeed(entries: [], config: cfg, store: tempStore())
        await #expect(throws: AggregatorError.self) { try await agg.aggregate() }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RSSPipelineAggregatorTests`
Expected: FAIL — `cannot find 'RSSPipelineAggregator' in scope`.

- [ ] **Step 3: Implement the base class**

Create `Yana/Aggregators/Concrete/RSSPipelineAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Ports the server's RssAggregator template method. Subclasses override hooks, not `aggregate()`.
/// `@unchecked Sendable`: instances are created per-run and not shared across tasks.
class RSSPipelineAggregator: Aggregator, @unchecked Sendable {
    let config: FeedConfig
    let credentials: AggregatorCredentials
    let store: ImageStore

    init(config: FeedConfig, credentials: AggregatorCredentials, store: ImageStore = .shared) {
        self.config = config
        self.credentials = credentials
        self.store = store
    }

    func validate() throws {
        if config.identifier.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AggregatorError.missingIdentifier
        }
    }

    func aggregate() async throws -> [AggregatedArticle] {
        try validate()
        let entries = try await fetchEntries()
        let limited = Array(entries.prefix(max(config.dailyLimit, 1)))
        var result: [AggregatedArticle] = []
        for entry in limited {
            let base = makeArticle(from: entry)
            let enriched = try await enrich(base, entry: entry)
            result.append(enriched)
        }
        return try await finalize(result)
    }

    // MARK: - Hooks

    func fetchEntries() async throws -> [FeedEntry] {
        guard let url = URL(string: config.identifier) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(url)
        return try FeedParser.parse(data).entries
    }

    func makeArticle(from entry: FeedEntry) -> AggregatedArticle {
        let content = entry.content ?? entry.summary ?? entry.entryDescription ?? ""
        return AggregatedArticle(
            title: entry.title,
            identifier: entry.link,
            url: entry.link,
            rawContent: content,
            content: content,
            date: entry.published ?? .now,
            author: entry.author,
            iconURL: nil
        )
    }

    func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        article.content = try await processContent(article.content, article: article, headerHTML: nil)
        return article
    }

    func processContent(_ html: String, article: AggregatedArticle, headerHTML: String?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        try EmbedRewriter.rewriteEmbeds(in: doc)
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: headerHTML, commentsHTML: nil)
    }

    func finalize(_ articles: [AggregatedArticle]) async throws -> [AggregatedArticle] { articles }

    var contentSelector: String { "" }
    var selectorsToRemove: [String] { [] }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RSSPipelineAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/RSSPipelineAggregator.swift YanaTests/RSSPipelineAggregatorTests.swift
git commit -m "feat: RSSPipelineAggregator template-method base class"
```

---

## Task 2: `FeedContentAggregator`

**Files:**
- Create: `Yana/Aggregators/Concrete/FeedContentAggregator.swift`
- Test: `YanaTests/FeedContentAggregatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/FeedContentAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("FeedContentAggregator")
struct FeedContentAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    final class StubFeedContent: FeedContentAggregator, @unchecked Sendable {
        let entries: [FeedEntry]
        init(entries: [FeedEntry], store: ImageStore) {
            self.entries = entries
            super.init(config: FeedConfig(type: .feedContent, identifier: "u", dailyLimit: 20,
                                          options: .feedContent(FeedContentOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
    }

    @Test func usesRssContentAndDownloadsImages() async throws {
        let entry = FeedEntry(title: "T", link: "https://x.com/1",
                              content: "<p>Body</p><img src=\"https://x.com/p.png\">",
                              summary: nil, entryDescription: nil, published: .now, author: "",
                              enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
        let agg = StubFeedContent(entries: [entry], store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Body"))
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))   // image localized
        #expect(!a.content.contains("https://x.com/p.png"))           // no remote URL
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedContentAggregatorTests`
Expected: FAIL — `cannot find 'FeedContentAggregator' in scope`.

- [ ] **Step 3: Implement `FeedContentAggregator`**

Create `Yana/Aggregators/Concrete/FeedContentAggregator.swift`:

```swift
import Foundation

/// RSS-only: uses feed entry content as-is (no full-article fetch). Mirrors FeedContentAggregator.
/// Inherits the base pipeline; images are still downloaded (decision 3).
class FeedContentAggregator: RSSPipelineAggregator, @unchecked Sendable {}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedContentAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/FeedContentAggregator.swift YanaTests/FeedContentAggregatorTests.swift
git commit -m "feat: FeedContentAggregator (RSS content as-is)"
```

---

## Task 3: `FullWebsiteAggregator`

**Files:**
- Create: `Yana/Aggregators/Concrete/FullWebsiteAggregator.swift`
- Test: `YanaTests/FullWebsiteAggregatorTests.swift`

- [ ] **Step 1: Write the failing test (inject feed entries + page HTML)**

Create `YanaTests/FullWebsiteAggregatorTests.swift`:

```swift
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
        var opts = WebsiteOptions(); opts.useFullContent = false
        let entry = FeedEntry(title: "T", link: "https://x.com/1", content: "<p>just summary</p>",
                              summary: "<p>just summary</p>", entryDescription: nil, published: .now, author: "",
                              enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
        final class S: FullWebsiteAggregator, @unchecked Sendable {
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
        let agg = S([entry], tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("just summary"))
        #expect(!a.content.contains("SHOULD NOT FETCH"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FullWebsiteAggregatorTests`
Expected: FAIL — `cannot find 'FullWebsiteAggregator' in scope`.

- [ ] **Step 3: Implement `FullWebsiteAggregator`**

Create `Yana/Aggregators/Concrete/FullWebsiteAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Fetches the article page and extracts main content via CSS selectors, hoisting a header
/// element and downloading images. Scrapers (4d) subclass this and override the selectors/hooks.
class FullWebsiteAggregator: RSSPipelineAggregator, @unchecked Sendable {
    override var contentSelector: String { "article, .article-content, .entry-content, main" }
    override var selectorsToRemove: [String] {
        ["script", "style",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])",
         "noscript", ".advertisement", ".ad", ".social-share"]
    }

    /// Overridable for tests.
    func fetchArticleHTML(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        return try await HTTPClient.fetchHTML(u)
    }

    /// The `WebsiteOptions` for this run (scrapers may have their own options; default to RSS-only behavior).
    var websiteOptions: WebsiteOptions {
        if case .fullWebsite(let o) = config.options { return o }
        return WebsiteOptions()
    }

    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        let opts = websiteOptions
        guard opts.useFullContent else {
            // Keep RSS summary, still localize images + embeds.
            article.content = try await processContent(article.content, article: article, headerHTML: nil)
            return article
        }
        do {
            let header = await HeaderElementExtractor.extract(
                articleURL: article.url, title: article.title, store: store, credentials: credentials)
            let raw = try await fetchArticleHTML(article.url)
            article.rawContent = raw

            let selector = opts.customContentSelector.isEmpty ? contentSelector : opts.customContentSelector
            var removeSelectors = selectorsToRemove
            if !opts.customSelectorsToRemove.isEmpty {
                removeSelectors += opts.customSelectorsToRemove.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let extracted = try HTMLUtils.extractMainContent(raw, selector: selector, removeSelectors: removeSelectors)
            article.content = try await processFullContent(extracted, article: article, header: header)
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }   // propagate 4xx skip to caller
            return article                                  // other errors: keep RSS content
        } catch {
            return article
        }
    }

    /// Like base processContent but de-dups the header image from the body and prepends the header.
    func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FullWebsiteAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/FullWebsiteAggregator.swift YanaTests/FullWebsiteAggregatorTests.swift
git commit -m "feat: FullWebsiteAggregator (page fetch + content extraction + header)"
```

---

## Task 4: Register generic aggregators + end-to-end service test

**Files:**
- Modify: `Yana/Aggregators/AggregatorRegistry.swift`
- Test: `YanaTests/AggregatorRegistryGenericTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregatorRegistryGenericTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry — generic")
struct AggregatorRegistryGenericTests {
    @Test func buildsFeedContentAndFullWebsite() {
        let feedCfg = FeedConfig(type: .feedContent, identifier: "u", dailyLimit: 20,
                                 options: .feedContent(FeedContentOptions()), collectedToday: 0)
        let webCfg = FeedConfig(type: .fullWebsite, identifier: "u", dailyLimit: 20,
                                options: .fullWebsite(WebsiteOptions()), collectedToday: 0)
        #expect(AggregatorRegistry.shared.makeAggregator(feedCfg, credentials: .init()) is FeedContentAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(webCfg, credentials: .init()) is FullWebsiteAggregator)
    }

    @Test func unregisteredTypeStillNil() {
        let cfg = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 20,
                             options: .reddit(RedditOptions()), collectedToday: 0)
        #expect(AggregatorRegistry.shared.makeAggregator(cfg, credentials: .init()) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregatorRegistryGenericTests`
Expected: FAIL — registry returns `nil` for all types.

- [ ] **Step 3: Wire the registry**

Replace the body of `makeAggregator` in `Yana/Aggregators/AggregatorRegistry.swift`:

```swift
    func makeAggregator(_ config: FeedConfig, credentials: AggregatorCredentials) -> (any Aggregator)? {
        switch config.type {
        case .feedContent: return FeedContentAggregator(config: config, credentials: credentials)
        case .fullWebsite: return FullWebsiteAggregator(config: config, credentials: credentials)
        // 4d scrapers and 4e social/media add their cases here.
        default: return nil
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregatorRegistryGenericTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS. (The 4a `missingAggregatorRecordsError` test used `.feedContent`; now that it resolves, update that test to use `.reddit` — still unregistered — so it still asserts the nil-aggregator path.)

- [ ] **Step 6: Update the 4a nil-aggregator test to an unregistered type**

In `YanaTests/AggregationServiceTests.swift`, change the `missingAggregatorRecordsError` test's feed to an unregistered type:

```swift
        let feed = Feed(name: "A", aggregatorType: .reddit, identifier: "swift")
```

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationServiceTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Yana/Aggregators/AggregatorRegistry.swift YanaTests/AggregatorRegistryGenericTests.swift YanaTests/AggregationServiceTests.swift
git commit -m "feat: register feedContent + fullWebsite aggregators"
```

---

## Self-Review

**Spec coverage (§4.1):** template-method pipeline (T1), `feedContent` RSS-as-is + image download
(T2), `fullWebsite` with `useFullContent`/`customContentSelector`/`customSelectorsToRemove`,
default selectors, header hoist + image dedup (T3), registry + service end-to-end (T4). Covered.

**Placeholders:** none — complete code or exact command+expected in every step.

**Type consistency:** uses the 4b contract verbatim (`HTTPClient.fetchData`, `FeedParser.parse`,
`HTMLUtils.*`, `EmbedRewriter.rewriteEmbeds`, `rewriteImages`, `HeaderElementExtractor.extract`,
`ContentFormatter.format`, `ReaderWeb.imageScheme`) and the 4a contract (`FeedConfig`,
`Aggregator`, `AggregatorError`, `AggregatorRegistry.makeAggregator`). Exposes the documented
base-class hooks for 4d/4e (`contentSelector`, `selectorsToRemove`, `fetchEntries`,
`fetchArticleHTML`, `processContent`, `processFullContent`, `enrich`, `finalize`).
