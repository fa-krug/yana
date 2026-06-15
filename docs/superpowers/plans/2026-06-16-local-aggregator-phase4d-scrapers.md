# Phase 4d — Site-Specific Scrapers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the six managed site scrapers — Heise, Merkur, Tagesschau, Caschy's Blog, MacTechNews, Mein-MMO — as `FullWebsiteAggregator` subclasses that faithfully reproduce the server's selectors, skip-lists, comment/media extraction, page-combining, and embed handling. Register them in `AggregatorRegistry`, and surface each scraper's predefined RSS-feed choices as a Picker in the feed editor.

**Architecture:** Each scraper is a `class XAggregator: FullWebsiteAggregator` that overrides only the hooks it needs (`fetchEntries`, `contentSelector`, `selectorsToRemove`, `shouldInclude`, `postFilter`, `enrich`, `processContent`, `processFullContent`, `fetchArticleHTML`). Scrapers read their **own** typed options case off `config.options` via a computed accessor (not `websiteOptions`, which is only meaningful for `fullWebsite`). Predefined/forced feeds are implemented by overriding `fetchEntries()` to fetch `config.identifier` if set, else the scraper's default RSS URL. Extra page fetches (Heise forum comments, Tagesschau media headers, Mein-MMO pagination) are isolated behind overridable methods so tests inject inline HTML fixtures — **no live network in tests**. Each scraper exposes a static `identifierChoices` table; a final task wires those into `FeedEditorView` as a Picker.

**Tech Stack:** Swift 6 (strict concurrency, `@unchecked Sendable` aggregator instances), SwiftSoup, SwiftData, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-16-local-aggregator-phase4-design.md` (§4.2).

**Depends on:** 4a (FeedConfig, Aggregator, AggregatorError, AggregatorRegistry.makeAggregator), 4b (HTTPClient, HTMLUtils, ContentFormatter, EmbedRewriter, ImageStore, rewriteImages, HeaderElementExtractor, ReaderWeb), 4c (RSSPipelineAggregator, FullWebsiteAggregator + hooks).

---

## Inherited contracts (reused verbatim from 4c)

These are the 4c base-class hooks every scraper overrides. Keep the signatures identical.

```swift
class FullWebsiteAggregator: RSSPipelineAggregator, @unchecked Sendable {
    let config: FeedConfig
    let credentials: AggregatorCredentials
    let store: ImageStore
    init(config: FeedConfig, credentials: AggregatorCredentials, store: ImageStore = .shared)

    func validate() throws
    func aggregate() async throws -> [AggregatedArticle]            // template method — do NOT override

    func fetchEntries() async throws -> [FeedEntry]                 // override to force/predefine the RSS URL
    func makeArticle(from entry: FeedEntry) -> AggregatedArticle
    func shouldInclude(_ article: AggregatedArticle) -> Bool        // pre-enrich title/url skip-lists
    func postFilter(_ article: AggregatedArticle) -> Bool           // post-enrich content-based skip
    func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle
    func processContent(_ html: String, article: AggregatedArticle, headerHTML: String?) async throws -> String
    func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String
    func fetchArticleHTML(_ url: String) async throws -> String     // override in tests to inject page HTML
    func finalize(_ articles: [AggregatedArticle]) async throws -> [AggregatedArticle]

    var contentSelector: String { get }
    var selectorsToRemove: [String] { get }
    var websiteOptions: WebsiteOptions { get }                       // fullWebsite-only; scrapers ignore this
}
```

**Key design notes (apply to every scraper task):**

- **Own options accessor, not `websiteOptions`.** Each scraper adds a computed accessor that
  pattern-matches its own case, e.g.
  `var heiseOptions: HeiseOptions { if case .heise(let o) = config.options { return o }; return HeiseOptions() }`.
  Scrapers do **not** override `websiteOptions` — they read behavior flags off their own options.
- **Force `useFullContent`.** Scrapers always fetch the article page. Because `FullWebsiteAggregator.enrich`
  gates on `websiteOptions.useFullContent` (default `true` for a fresh `WebsiteOptions()`), and the scraper's
  config carries its own (non-`fullWebsite`) options case, `websiteOptions` returns a default `WebsiteOptions()`
  whose `useFullContent == true`. The full-content path therefore runs for every scraper without extra work.
- **Forced/predefined feeds.** Override `fetchEntries()` to pick `config.identifier` when non-empty, else the
  scraper's default RSS URL (MacTechNews forces its feed regardless of `config.identifier`).
- **Extra page fetches are overridable.** Comment/media/pagination fetches go through dedicated `func`s
  (`fetchCommentsHTML`, `fetchMediaPageHTML`, `fetchAdditionalPage`) that tests subclass and replace with
  inline string fixtures.
- **Static `identifierChoices`.** Each scraper type exposes `static let identifierChoices: [(value: String, label: String)]`
  for the editor Picker (final task). MacTechNews has none (forced); Tagesschau/Heise/Merkur/Caschy/Mein-MMO do.

Build/test command:

```
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

To run a single suite: append `-only-testing:YanaTests/<Suite>`.

---

## File Structure

- Create `Yana/Aggregators/Concrete/HeiseAggregator.swift`
- Create `Yana/Aggregators/Concrete/MerkurAggregator.swift`
- Create `Yana/Aggregators/Concrete/TagesschauAggregator.swift`
- Create `Yana/Aggregators/Concrete/CaschysBlogAggregator.swift`
- Create `Yana/Aggregators/Concrete/MactechnewsAggregator.swift`
- Create `Yana/Aggregators/Concrete/MeinMmoAggregator.swift`
- Modify `Yana/Aggregators/AggregatorRegistry.swift` — add the six cases.
- Modify `Yana/Views/Config/FeedEditorView.swift` — RSS-feed-choice Picker.
- Create `YanaTests/HeiseAggregatorTests.swift`, `YanaTests/MerkurAggregatorTests.swift`,
  `YanaTests/TagesschauAggregatorTests.swift`, `YanaTests/CaschysBlogAggregatorTests.swift`,
  `YanaTests/MactechnewsAggregatorTests.swift`, `YanaTests/MeinMmoAggregatorTests.swift`,
  `YanaTests/AggregatorRegistryScrapersTests.swift`.

---

## Task 1: `HeiseAggregator`

Ports `core/aggregators/heise/aggregator.py`: `seite=all` multi-page URL, `#meldung, .StoryContent`
content selector, the full server remove-list, the title skip-list (`shouldInclude`), the
"Event Sourcing" content skip (`postFilter`), empty-element removal, and forum comments
(JSON-LD `discussionUrl` → fallback forum link → comment selectors → blockquotes), gated by
`includeComments` and capped at `maxComments`, threaded into `ContentFormatter` as `commentsHTML`.

**Files:**
- Create: `Yana/Aggregators/Concrete/HeiseAggregator.swift`
- Test: `YanaTests/HeiseAggregatorTests.swift`

- [ ] **Step 1: Write the failing test (inject feed entry, article page, and forum page)**

Create `YanaTests/HeiseAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("HeiseAggregator")
struct HeiseAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry(_ title: String, link: String = "https://heise.de/-1") -> FeedEntry {
        FeedEntry(title: title, link: link, content: "<p>summary</p>", summary: "<p>summary</p>",
                  entryDescription: nil, published: .now, author: "", enclosures: [],
                  itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    /// Subclass injecting feed entries, the article page, and forum HTML.
    final class StubHeise: HeiseAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String; let forum: String
        var requestedArticleURL: String?
        init(entries: [FeedEntry], page: String, forum: String, options: HeiseOptions, store: ImageStore) {
            self.entries = entries; self.page = page; self.forum = forum
            super.init(config: FeedConfig(type: .heise, identifier: "https://www.heise.de/rss/heise.rdf",
                                          dailyLimit: 20, options: .heise(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { requestedArticleURL = url; return page }
        override func fetchCommentsHTML(_ url: String) async throws -> String { forum }
    }

    @Test func extractsStoryContentAndAppendsAllPagesParam() async throws {
        let page = """
        <html><body><article class="StoryContent"><p>Real body</p>\
        <section>nav junk</section><p></p></article></body></html>
        """
        let agg = StubHeise(entries: [entry("Normal article")], page: page, forum: "",
                            options: { var o = HeiseOptions(); o.includeComments = false; return o }(),
                            store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Real body"))
        #expect(!a.content.contains("nav junk"))        // <section> removed
        #expect(agg.requestedArticleURL?.contains("seite=all") == true)
    }

    @Test func skipsTitlesInSkipList() async throws {
        let agg = StubHeise(entries: [entry("heise+ exclusive"), entry("Keeper")],
                            page: "<article class=\"StoryContent\"><p>x</p></article>", forum: "",
                            options: { var o = HeiseOptions(); o.includeComments = false; return o }(),
                            store: tempStore())
        let titles = try await agg.aggregate().map(\.title)
        #expect(titles == ["Keeper"])
    }

    @Test func skipsEventSourcingInContent() async throws {
        let page = "<article class=\"StoryContent\"><p>About Event Sourcing patterns</p></article>"
        let agg = StubHeise(entries: [entry("Patterns")], page: page, forum: "",
                            options: { var o = HeiseOptions(); o.includeComments = false; return o }(),
                            store: tempStore())
        #expect(try await agg.aggregate().isEmpty)
    }

    @Test func extractsForumCommentsAsBlockquotesCappedAtMax() async throws {
        let page = """
        <html><head><script type="application/ld+json">\
        {"discussionUrl": "https://www.heise.de/forum/123/"}</script></head>\
        <body><article class="StoryContent"><p>Body</p></article></body></html>
        """
        let forum = """
        <ul><li class="posting_element"><span class="pseudonym">Alice</span>\
        <a class="posting_subject" href="/forum/p1">First take</a></li>\
        <li class="posting_element"><span class="pseudonym">Bob</span>\
        <a class="posting_subject" href="/forum/p2">Second take</a></li>\
        <li class="posting_element"><span class="pseudonym">Carol</span>\
        <a class="posting_subject" href="/forum/p3">Third take</a></li></ul>
        """
        let agg = StubHeise(entries: [entry("With comments")], page: page, forum: forum,
                            options: { var o = HeiseOptions(); o.includeComments = true; o.maxComments = 2; return o }(),
                            store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("article-comments"))
        #expect(a.content.contains("First take"))
        #expect(a.content.contains("Second take"))
        #expect(!a.content.contains("Third take"))      // capped at maxComments = 2
        #expect(a.content.contains("<blockquote"))
    }

    @Test func identifierChoicesHasFourHeiseFeeds() {
        #expect(HeiseAggregator.identifierChoices.count == 4)
        #expect(HeiseAggregator.identifierChoices.first?.value == "https://www.heise.de/rss/heise.rdf")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HeiseAggregatorTests`
Expected: FAIL — `cannot find 'HeiseAggregator' in scope`.

- [ ] **Step 3: Implement `HeiseAggregator`**

Create `Yana/Aggregators/Concrete/HeiseAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Heise.de German tech news. Ports core/aggregators/heise/aggregator.py:
/// `seite=all` multi-page fetch, `#meldung, .StoryContent`, full remove-list, title/content
/// skip-lists, empty-element removal, and forum comments rendered as blockquotes.
final class HeiseAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://www.heise.de/rss/heise.rdf"
    static let heiseURL = "https://www.heise.de/"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://www.heise.de/rss/heise.rdf", "Main Feed"),
        ("https://www.heise.de/rss/heise-security.rdf", "Security"),
        ("https://www.heise.de/rss/heise-developer.rdf", "Developer"),
        ("https://www.heise.de/rss/heise-top.rdf", "Top News"),
    ]

    static let titleSkipList = [
        "die Bilder der Woche", "Produktwerker", "heise-Angebot", "#TGIQF", "heise+",
        "#heiseshow:", "Mein Scrum ist kaputt", "software-architektur.tv", "Developer Snapshots",
    ]

    var heiseOptions: HeiseOptions {
        if case .heise(let o) = config.options { return o }
        return HeiseOptions()
    }

    override var contentSelector: String { "#meldung, .StoryContent" }

    override var selectorsToRemove: [String] {
        [".ad-label", ".ad", ".article-sidebar", "section",
         "a[name='meldung.ho.bottom.zurstartseite']",
         ".a-article-header__lead", ".a-article-header__title",
         ".a-article-header__publish-info", ".a-article-header__service",
         "a-lightbox.article-image", "figure.a-article-header__image",
         "div[data-component='RecommendationBox']", ".opt-in__content-container", ".a-box",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])",
         ".a-u-inline", ".redakteurskuerzel", ".branding", "a-gift", "aside",
         "script", "style", "noscript", "footer", ".rte__list",
         "#wtma_teaser_ho_vertrieb_inline_branding"]
    }

    // MARK: - Predefined feed

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    // MARK: - Filters

    override func shouldInclude(_ article: AggregatedArticle) -> Bool {
        !Self.titleSkipList.contains { article.title.contains($0) }
    }

    override func postFilter(_ article: AggregatedArticle) -> Bool {
        !article.content.lowercased().contains("event sourcing")
    }

    // MARK: - Multi-page article URL

    override func fetchArticleHTML(_ url: String) async throws -> String {
        var articleURL = url
        if !url.contains("seite=all") {
            articleURL = url.contains("?") ? "\(url)&seite=all" : "\(url)?seite=all"
        }
        guard let u = URL(string: articleURL) else { throw AggregatorError.missingIdentifier }
        return try await HTTPClient.fetchHTML(u)
    }

    /// Overridable for tests: fetches the forum page HTML.
    func fetchCommentsHTML(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw AggregatorError.contentFetch("bad forum url") }
        return try await HTTPClient.fetchHTML(u)
    }

    // MARK: - Content processing (override to inject comments before the footer)

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        // Empty-element removal (server: p/div/span with no text and no images).
        try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div", "span"])
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)

        // Forum comments from the raw page HTML (rawContent set by FullWebsiteAggregator.enrich).
        var commentsHTML: String? = nil
        if heiseOptions.includeComments {
            commentsHTML = try? await extractComments(articleURL: article.url, pageHTML: article.rawContent,
                                                      maxComments: heiseOptions.maxComments)
        }
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: commentsHTML)
    }

    // MARK: - Comment extraction

    func extractComments(articleURL: String, pageHTML: String, maxComments: Int) async throws -> String? {
        guard maxComments > 0 else { return nil }
        let base = articleURL.contains("heise.de/-") ? Self.heiseURL : articleURL
        guard let forumURL = try findForumURL(pageHTML: pageHTML, base: base) else { return nil }

        let forumHTML = try await fetchCommentsHTML(forumURL)
        let doc = try HTMLUtils.parse(forumHTML)
        let elements = try findCommentElements(doc)
        guard !elements.isEmpty else { return nil }

        var parts: [String] = []
        for el in elements.prefix(maxComments) {
            if let html = try processCommentElement(el) { parts.append(html) }
        }
        guard !parts.isEmpty else { return nil }
        let header = "<h3><a href=\"\(forumURL)\">Comments</a></h3>"
        return "<section>\(header)\(parts.joined())</section>"
    }

    private func findForumURL(pageHTML: String, base: String) throws -> String? {
        let doc = try HTMLUtils.parse(pageHTML)
        // 1. JSON-LD discussionUrl.
        for script in try doc.select("script[type=application/ld+json]") {
            let raw = try script.html()
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            let items: [[String: Any]] = (obj as? [[String: Any]]) ?? [(obj as? [String: Any])].compactMap { $0 }
            for item in items {
                if let discussion = item["discussionUrl"] as? String {
                    return URL(string: discussion, relativeTo: URL(string: base))?.absoluteString ?? discussion
                }
            }
        }
        // 2. Fallback forum link.
        if let a = try doc.select("a[href*=/forum/][href*=comment], footer a[href*=/forum/]").first() {
            let href = try a.attr("href")
            if !href.isEmpty {
                return URL(string: href, relativeTo: URL(string: base))?.absoluteString ?? href
            }
        }
        return nil
    }

    private func findCommentElements(_ doc: Document) throws -> [Element] {
        for selector in ["li.posting_element", "[id^=posting_]", ".posting", ".a-comment"] {
            let found = try doc.select(selector).array()
            if !found.isEmpty { return found }
        }
        return []
    }

    private func processCommentElement(_ el: Element) throws -> String? {
        if el.tagName() == "li" { return try processListItemComment(el) }
        return try processFullViewComment(el)
    }

    private func processListItemComment(_ el: Element) throws -> String? {
        var author = "Unknown"
        if let a = try el.select(".tree_thread_list--written_by_user, .pseudonym").first() {
            author = try a.text()
        }
        guard let link = try el.select("a.posting_subject").first() else { return nil }
        let title = try link.text()
        let href = try link.attr("href")
        let commentURL = URL(string: href, relativeTo: URL(string: Self.heiseURL))?.absoluteString ?? href
        return "<blockquote><p><strong>\(author)</strong> | <a href=\"\(commentURL)\">source</a></p>"
            + "<div><p>\(title)</p></div></blockquote>"
    }

    private func processFullViewComment(_ el: Element) throws -> String? {
        var author = "Unknown"
        for selector in ["a[href*=/forum/heise-online/Meinungen]", ".pseudonym", ".username", "strong"] {
            if let a = try el.select(selector).first() {
                let text = try a.text()
                if !text.isEmpty, text.count < 50 { author = text; break }
            }
        }
        var content = ""
        for selector in [".text", ".posting-content", ".comment-body", "p"] {
            if let c = try el.select(selector).first() { content = try c.outerHtml(); break }
        }
        guard !content.isEmpty else { return nil }
        let id = (try? el.attr("id")) ?? ""
        let anchor = id.isEmpty ? "comment" : id
        return "<blockquote><p><strong>\(author)</strong> | <a href=\"#\(anchor)\">source</a></p>"
            + "<div>\(content)</div></blockquote>"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HeiseAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/HeiseAggregator.swift YanaTests/HeiseAggregatorTests.swift
git commit -m "feat: HeiseAggregator (seite=all, StoryContent, skip-lists, forum comments)"
```

---

## Task 2: `MerkurAggregator`

Ports `core/aggregators/merkur/aggregator.py`: `.idjs-Story` content selector, the full
server remove-list, optional empty-element removal (`removeEmptyElements`), and the 18
regional feed choices (default main).

**Files:**
- Create: `Yana/Aggregators/Concrete/MerkurAggregator.swift`
- Test: `YanaTests/MerkurAggregatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/MerkurAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("MerkurAggregator")
struct MerkurAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry() -> FeedEntry {
        FeedEntry(title: "Merkur story", link: "https://www.merkur.de/a-1", content: "<p>s</p>",
                  summary: "<p>s</p>", entryDescription: nil, published: .now, author: "",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubMerkur: MerkurAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, options: MerkurOptions, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .merkur, identifier: "https://www.merkur.de/rssfeed.rdf",
                                          dailyLimit: 20, options: .merkur(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func extractsIdjsStoryAndRemovesEmptyWhenEnabled() async throws {
        let page = """
        <html><body><div class="idjs-Story"><p>Keep this</p><p></p>\
        <figcaption>caption</figcaption></div></body></html>
        """
        let agg = StubMerkur(entries: [entry()], page: page, options: MerkurOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Keep this"))
        #expect(!a.content.contains("caption"))                 // figcaption removed
        #expect(a.content.replacingOccurrences(of: "Keep this", with: "").contains("<p></p>") == false)
    }

    @Test func keepsEmptyWhenRemoveEmptyDisabled() async throws {
        let page = "<div class=\"idjs-Story\"><p>Body</p><p></p></div>"
        let agg = StubMerkur(entries: [entry()], page: page,
                             options: { var o = MerkurOptions(); o.removeEmptyElements = false; return o }(),
                             store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("<p></p>"))
    }

    @Test func identifierChoicesHas18RegionalFeeds() {
        #expect(MerkurAggregator.identifierChoices.count == 18)
        #expect(MerkurAggregator.identifierChoices.first?.value == "https://www.merkur.de/rssfeed.rdf")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MerkurAggregatorTests`
Expected: FAIL — `cannot find 'MerkurAggregator' in scope`.

- [ ] **Step 3: Implement `MerkurAggregator`**

Create `Yana/Aggregators/Concrete/MerkurAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Merkur.de German regional news. Ports core/aggregators/merkur/aggregator.py:
/// `.idjs-Story` content, full remove-list, optional empty-element removal, 18 regional feeds.
final class MerkurAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://www.merkur.de/rssfeed.rdf"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://www.merkur.de/rssfeed.rdf", "Main Feed"),
        ("https://www.merkur.de/lokales/garmisch-partenkirchen/rssfeed.rdf", "Garmisch-Partenkirchen"),
        ("https://www.merkur.de/lokales/wuermtal/rssfeed.rdf", "Würmtal"),
        ("https://www.merkur.de/lokales/starnberg/rssfeed.rdf", "Starnberg"),
        ("https://www.merkur.de/lokales/fuerstenfeldbruck/rssfeed.rdf", "Fürstenfeldbruck"),
        ("https://www.merkur.de/lokales/dachau/rssfeed.rdf", "Dachau"),
        ("https://www.merkur.de/lokales/freising/rssfeed.rdf", "Freising"),
        ("https://www.merkur.de/lokales/erding/rssfeed.rdf", "Erding"),
        ("https://www.merkur.de/lokales/ebersberg/rssfeed.rdf", "Ebersberg"),
        ("https://www.merkur.de/lokales/muenchen/rssfeed.rdf", "München"),
        ("https://www.merkur.de/lokales/muenchen-lk/rssfeed.rdf", "München Landkreis"),
        ("https://www.merkur.de/lokales/holzkirchen/rssfeed.rdf", "Holzkirchen"),
        ("https://www.merkur.de/lokales/miesbach/rssfeed.rdf", "Miesbach"),
        ("https://www.merkur.de/lokales/region-tegernsee/rssfeed.rdf", "Region Tegernsee"),
        ("https://www.merkur.de/lokales/bad-toelz/rssfeed.rdf", "Bad Tölz"),
        ("https://www.merkur.de/lokales/wolfratshausen/rssfeed.rdf", "Wolfratshausen"),
        ("https://www.merkur.de/lokales/weilheim/rssfeed.rdf", "Weilheim"),
        ("https://www.merkur.de/lokales/schongau/rssfeed.rdf", "Schongau"),
    ]

    var merkurOptions: MerkurOptions {
        if case .merkur(let o) = config.options { return o }
        return MerkurOptions()
    }

    override var contentSelector: String { ".idjs-Story" }

    override var selectorsToRemove: [String] {
        [".id-DonaldBreadcrumb--default", ".id-StoryElement-headline", ".id-StoryElement-image",
         ".lp_west_printAction", ".lp_west_webshareAction", ".id-Recommendation", ".enclosure",
         ".id-Story-timestamp", ".id-Story-authors", ".id-Story-interactionBar", ".id-Comments",
         ".id-ClsPrevention", "egy-discussion", "figcaption", "script", "style",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])", "noscript", "svg",
         ".id-StoryElement-intestitialLink", ".id-StoryElement-embed--fanq"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        if merkurOptions.removeEmptyElements {
            try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div", "span"])
        }
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

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MerkurAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/MerkurAggregator.swift YanaTests/MerkurAggregatorTests.swift
git commit -m "feat: MerkurAggregator (.idjs-Story, remove-list, regional feeds)"
```

---

## Task 3: `TagesschauAggregator`

Ports `core/aggregators/tagesschau/`: textabsatz-`<p>` + trenner-`<h2>` extraction (skipping
teaser/bigfive/accordion/related ancestors), HTML5 media-header extraction from
`div[data-v-type=MediaPlayer]`, livestream/video/podcast skip-lists, and the 42 feed choices
(default "Alle Meldungen"). Tagesschau's `identifierKind` is `.none`, so the editor uses the
predefined picker exclusively.

**Files:**
- Create: `Yana/Aggregators/Concrete/TagesschauAggregator.swift`
- Test: `YanaTests/TagesschauAggregatorTests.swift`

- [ ] **Step 1: Write the failing test (inject entry + article page with MediaPlayer)**

Create `YanaTests/TagesschauAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("TagesschauAggregator")
struct TagesschauAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry(_ title: String, link: String = "https://www.tagesschau.de/inland/story-1.html") -> FeedEntry {
        FeedEntry(title: title, link: link, content: "<p>s</p>", summary: "<p>s</p>",
                  entryDescription: nil, published: .now, author: "", enclosures: [],
                  itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubTS: TagesschauAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, options: TagesschauOptions, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .tagesschau,
                                          identifier: "https://www.tagesschau.de/infoservices/alle-meldungen-100~rss2.xml",
                                          dailyLimit: 20, options: .tagesschau(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func extractsOnlyTextabsatzAndTrennerSkippingTeaser() async throws {
        let page = """
        <html><body>
        <p class="textabsatz">Real paragraph</p>
        <h2 class="trenner">Section heading</h2>
        <div class="teaser"><p class="textabsatz">Teaser noise</p></div>
        <p class="other">Ignored</p>
        </body></html>
        """
        let agg = StubTS(entries: [entry("Politik aktuell")], page: page, options: TagesschauOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Real paragraph"))
        #expect(a.content.contains("Section heading"))
        #expect(!a.content.contains("Teaser noise"))         // teaser ancestor skipped
        #expect(!a.content.contains("Ignored"))               // not textabsatz
    }

    @Test func buildsVideoMediaHeaderFromMediaPlayer() async throws {
        // data-v JSON uses &quot; entities, like the real page.
        let json = "{&quot;mc&quot;:{&quot;streams&quot;:[{&quot;media&quot;:[{&quot;url&quot;:&quot;https://t.de/v.mp4&quot;,&quot;mimeType&quot;:&quot;video/mp4&quot;}]}]}}"
        let page = """
        <html><body>
        <div data-v-type="MediaPlayer" class="mediaplayer teaser-top" data-v="\(json)"></div>
        <p class="textabsatz">Story text</p>
        </body></html>
        """
        let agg = StubTS(entries: [entry("Mit Video")], page: page, options: TagesschauOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("<video"))
        #expect(a.content.contains("https://t.de/v.mp4"))
        #expect(a.content.contains("Story text"))
    }

    @Test func skipsLivestreamAndPodcastTitlesAndVideoURLs() async throws {
        let agg = StubTS(entries: [
            entry("Livestream: Pressekonferenz"),
            entry("11KM-Podcast: Thema"),
            entry("Bericht", link: "https://www.tagesschau.de/multimedia/video/video-99.html"),
            entry("Keeper"),
        ], page: "<p class=\"textabsatz\">x</p>", options: TagesschauOptions(), store: tempStore())
        let titles = try await agg.aggregate().map(\.title)
        #expect(titles == ["Keeper"])
    }

    @Test func identifierChoicesMatchServerList() {
        #expect(TagesschauAggregator.identifierChoices.count == 42)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TagesschauAggregatorTests`
Expected: FAIL — `cannot find 'TagesschauAggregator' in scope`.

- [ ] **Step 3: Implement `TagesschauAggregator`**

Create `Yana/Aggregators/Concrete/TagesschauAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Tagesschau.de. Ports core/aggregators/tagesschau/: textabsatz/trenner extraction,
/// MediaPlayer header, livestream/podcast/video skip-lists, 42 predefined feeds.
final class TagesschauAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://www.tagesschau.de/infoservices/alle-meldungen-100~rss2.xml"
    static let baseURL = "https://www.tagesschau.de"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://www.tagesschau.de/infoservices/alle-meldungen-100~rss2.xml", "Alle Meldungen"),
        ("https://www.tagesschau.de/index~rss2.xml", "Startseite"),
        ("https://www.tagesschau.de/inland/index~rss2.xml", "Inland"),
        ("https://www.tagesschau.de/inland/innenpolitik/index~rss2.xml", "Innenpolitik"),
        ("https://www.tagesschau.de/inland/gesellschaft/index~rss2.xml", "Gesellschaft"),
        ("https://www.tagesschau.de/inland/regional/index~rss2.xml", "Regional (Alle)"),
        ("https://www.tagesschau.de/inland/regional/badenwuerttemberg/index~rss2.xml", "Baden-Württemberg"),
        ("https://www.tagesschau.de/inland/regional/bayern/index~rss2.xml", "Bayern"),
        ("https://www.tagesschau.de/inland/regional/berlin/index~rss2.xml", "Berlin"),
        ("https://www.tagesschau.de/inland/regional/brandenburg/index~rss2.xml", "Brandenburg"),
        ("https://www.tagesschau.de/inland/regional/bremen/index~rss2.xml", "Bremen"),
        ("https://www.tagesschau.de/inland/regional/hamburg/index~rss2.xml", "Hamburg"),
        ("https://www.tagesschau.de/inland/regional/hessen/index~rss2.xml", "Hessen"),
        ("https://www.tagesschau.de/inland/regional/mecklenburgvorpommern/index~rss2.xml", "Mecklenburg-Vorpommern"),
        ("https://www.tagesschau.de/inland/regional/niedersachsen/index~rss2.xml", "Niedersachsen"),
        ("https://www.tagesschau.de/inland/regional/nordrheinwestfalen/index~rss2.xml", "Nordrhein-Westfalen"),
        ("https://www.tagesschau.de/inland/regional/rheinlandpfalz/index~rss2.xml", "Rheinland-Pfalz"),
        ("https://www.tagesschau.de/inland/regional/saarland/index~rss2.xml", "Saarland"),
        ("https://www.tagesschau.de/inland/regional/sachsen/index~rss2.xml", "Sachsen"),
        ("https://www.tagesschau.de/inland/regional/sachsenanhalt/index~rss2.xml", "Sachsen-Anhalt"),
        ("https://www.tagesschau.de/inland/regional/schleswigholstein/index~rss2.xml", "Schleswig-Holstein"),
        ("https://www.tagesschau.de/inland/regional/thueringen/index~rss2.xml", "Thüringen"),
        ("https://www.tagesschau.de/ausland/index~rss2.xml", "Ausland"),
        ("https://www.tagesschau.de/ausland/europa/index~rss2.xml", "Europa"),
        ("https://www.tagesschau.de/ausland/amerika/index~rss2.xml", "Amerika"),
        ("https://www.tagesschau.de/ausland/afrika/index~rss2.xml", "Afrika"),
        ("https://www.tagesschau.de/ausland/asien/index~rss2.xml", "Asien"),
        ("https://www.tagesschau.de/ausland/ozeanien/index~rss2.xml", "Ozeanien"),
        ("https://www.tagesschau.de/wirtschaft/index~rss2.xml", "Wirtschaft"),
        ("https://www.tagesschau.de/wirtschaft/finanzen/index~rss2.xml", "Finanzen"),
        ("https://www.tagesschau.de/wirtschaft/unternehmen/index~rss2.xml", "Unternehmen"),
        ("https://www.tagesschau.de/wirtschaft/verbraucher/index~rss2.xml", "Verbraucher"),
        ("https://www.tagesschau.de/wirtschaft/technologie/index~rss2.xml", "Technologie (Wirtschaft)"),
        ("https://www.tagesschau.de/wirtschaft/weltwirtschaft/index~rss2.xml", "Weltwirtschaft"),
        ("https://www.tagesschau.de/wirtschaft/konjunktur/index~rss2.xml", "Konjunktur"),
        ("https://www.tagesschau.de/wissen/index~rss2.xml", "Wissen"),
        ("https://www.tagesschau.de/wissen/gesundheit/index~rss2.xml", "Gesundheit"),
        ("https://www.tagesschau.de/wissen/klima/index~rss2.xml", "Klima & Umwelt"),
        ("https://www.tagesschau.de/wissen/forschung/index~rss2.xml", "Forschung"),
        ("https://www.tagesschau.de/wissen/technologie/index~rss2.xml", "Technologie (Wissen)"),
        ("https://www.tagesschau.de/faktenfinder/index~rss2.xml", "Faktenfinder"),
        ("https://www.tagesschau.de/investigativ/index~rss2.xml", "Investigativ"),
    ]   // 42 feeds — exactly the server's list (core/aggregators/tagesschau/aggregator.py). Do not pad.

    static let titleSkipList = ["tagesschau", "tagesthemen", "11KM-Podcast", "Podcast 15 Minuten", "15 Minuten:"]

    var tagesschauOptions: TagesschauOptions {
        if case .tagesschau(let o) = config.options { return o }
        return TagesschauOptions()
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    // MARK: - Filtering

    override func shouldInclude(_ article: AggregatedArticle) -> Bool {
        let title = article.title
        let url = article.url
        let opts = tagesschauOptions
        if opts.skipLivestreams, title.contains("Livestream:") { return false }
        if Self.titleSkipList.contains(where: { title.contains($0) }) { return false }
        if url.contains("bilder/blickpunkte") { return false }
        if opts.skipVideos, url.lowercased().contains("video") { return false }
        return true
    }

    // MARK: - Content extraction (textabsatz / trenner only)

    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        do {
            let raw = try await fetchArticleHTML(article.url)
            article.rawContent = raw
            let extracted = try Self.extractTagesschauContent(raw)
            let mediaHeader = try? Self.extractMediaHeader(raw)
            // Standard processing without a generic header (media header handled separately).
            let body = try await processContent(extracted, article: article, headerHTML: nil)
            article.content = (mediaHeader ?? "") + body
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }
            return article
        } catch {
            return article
        }
    }

    /// textabsatz-`<p>` + trenner-`<h2>` only, skipping teaser/bigfive/accordion/related ancestors.
    static func extractTagesschauContent(_ html: String) throws -> String {
        let doc = try HTMLUtils.parse(html)
        let skipClasses = ["teaser", "bigfive", "accordion", "related"]
        var parts: [String] = []
        for el in try doc.select("p, h2") {
            if try hasSkippedAncestor(el, skipClasses: skipClasses) { continue }
            let classes = (try? el.classNames()) ?? []
            if el.tagName() == "p", classes.contains(where: { $0.contains("textabsatz") }) {
                let inner = try el.html()
                parts.append("<p>\(inner)</p>")
            } else if el.tagName() == "h2", classes.contains(where: { $0.contains("trenner") }) {
                let text = try el.text()
                parts.append("<h2>\(text)</h2>")
            }
        }
        return parts.joined()
    }

    private static func hasSkippedAncestor(_ el: Element, skipClasses: [String]) throws -> Bool {
        var current: Element? = el.parent()
        while let node = current {
            let classes = (try? node.classNames()) ?? []
            if classes.contains(where: { cls in skipClasses.contains { cls.contains($0) } }) { return true }
            current = node.parent()
        }
        return false
    }

    // MARK: - Media header (div[data-v-type=MediaPlayer])

    static func extractMediaHeader(_ html: String) throws -> String? {
        let doc = try HTMLUtils.parse(html)
        var players = try doc.select("div[data-v-type=MediaPlayer]").array().filter {
            ((try? $0.classNames()) ?? []).contains { $0.lowercased().contains("mediaplayer") }
        }
        let teaserTop = players.filter { ((try? $0.classNames()) ?? []).contains { $0.lowercased().contains("teaser-top") } }
        if !teaserTop.isEmpty { players = teaserTop }

        for player in players {
            let dataV = try player.attr("data-v")
            guard !dataV.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: Data(decodeEntities(dataV).utf8)) as? [String: Any],
                  let mc = json["mc"] as? [String: Any] else { continue }
            let streams = (mc["streams"] as? [[String: Any]]) ?? []
            let isAudioOnly = !streams.isEmpty && streams.allSatisfy { ($0["isAudioOnly"] as? Bool) == true }
            let imageURL = playerImage(player: player, mc: mc)
            if let html = buildHeaderFromStreams(streams: streams, isAudioOnly: isAudioOnly, imageURL: imageURL) {
                return html
            }
        }
        return nil
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func playerImage(player: Element, mc: [String: Any]) -> String? {
        let fields = ["poster", "image", "thumbnail", "preview", "cover"]
        for f in fields { if let v = mc[f] as? String, !v.isEmpty { return absolutize(v) } }
        for stream in (mc["streams"] as? [[String: Any]]) ?? [] {
            for f in fields { if let v = stream[f] as? String, !v.isEmpty { return absolutize(v) } }
        }
        return nil
    }

    private static func absolutize(_ url: String) -> String {
        if url.hasPrefix("//") { return "https:" + url }
        if url.hasPrefix("/") { return baseURL + url }
        return url
    }

    private static func buildHeaderFromStreams(streams: [[String: Any]], isAudioOnly: Bool, imageURL: String?) -> String? {
        if isAudioOnly {
            guard let media = findMedia(streams, type: "audio") else { return nil }
            let img = imageURL.map { "<div class=\"media-image\"><img src=\"\($0)\" alt=\"Article image\" style=\"max-width: 100%; height: auto; border-radius: 8px;\"></div>" } ?? ""
            return "<header class=\"media-header\">\(img)<div class=\"media-player\" style=\"width: 100%;\">"
                + "<audio controls preload=\"auto\" style=\"width: 100%;\"><source src=\"\(media.url)\" type=\"\(media.mime)\">"
                + "Your browser does not support the audio element.</audio></div></header>"
        } else {
            guard let media = findMedia(streams, type: "video") else { return nil }
            let poster = imageURL.map { "poster=\"\($0)\"" } ?? ""
            return "<header class=\"media-header\"><div class=\"media-player\" style=\"width: 100%;\">"
                + "<video controls preload=\"auto\" \(poster) style=\"width: 100%;\"><source src=\"\(media.url)\" type=\"\(media.mime)\">"
                + "Your browser does not support the video element.</video></div></header>"
        }
    }

    private static func findMedia(_ streams: [[String: Any]], type: String) -> (url: String, mime: String)? {
        for stream in streams {
            for media in (stream["media"] as? [[String: Any]]) ?? [] {
                if let url = media["url"] as? String {
                    let mime = (media["mimeType"] as? String) ?? ""
                    if mime.lowercased().contains(type) { return (url, mime) }
                }
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TagesschauAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/TagesschauAggregator.swift YanaTests/TagesschauAggregatorTests.swift
git commit -m "feat: TagesschauAggregator (textabsatz/trenner, media header, skip-lists, 42 feeds)"
```

---

## Task 4: `CaschysBlogAggregator`

Ports `core/aggregators/caschys_blog/aggregator.py`: `.entry-inner` content, `.aawp*` removal,
title skip ("(Anzeige)" gated by `skipAds`, and "Immer wieder sonntags KW" always), iframe
whitelist (YouTube + Twitter/X), relative-URL resolution, and first-image dedup. Single feed
`stadt-bremerhaven.de/feed/`.

**Files:**
- Create: `Yana/Aggregators/Concrete/CaschysBlogAggregator.swift`
- Test: `YanaTests/CaschysBlogAggregatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/CaschysBlogAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("CaschysBlogAggregator")
struct CaschysBlogAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry(_ title: String) -> FeedEntry {
        FeedEntry(title: title, link: "https://stadt-bremerhaven.de/post-1/", content: "<p>s</p>",
                  summary: "<p>s</p>", entryDescription: nil, published: .now, author: "",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubCaschy: CaschysBlogAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, options: CaschysBlogOptions, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .caschysBlog, identifier: "https://stadt-bremerhaven.de/feed/",
                                          dailyLimit: 20, options: .caschysBlog(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func extractsEntryInnerAndStripsAawpAndDisallowedIframe() async throws {
        let page = """
        <html><body><div class="entry-inner"><p>Body text</p>\
        <div class="aawp">affiliate</div>\
        <iframe src="https://evil.example.com/x"></iframe>\
        <iframe src="https://www.youtube.com/embed/abc12345678"></iframe>\
        </div></body></html>
        """
        let agg = StubCaschy(entries: [entry("Post")], page: page, options: CaschysBlogOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Body text"))
        #expect(!a.content.contains("affiliate"))            // .aawp removed
        #expect(!a.content.contains("evil.example.com"))      // disallowed iframe removed
        #expect(a.content.contains("youtube-nocookie.com/embed/abc12345678"))  // YouTube kept + rewritten
    }

    @Test func skipsAnzeigeAndWeeklyRecap() async throws {
        let agg = StubCaschy(entries: [
            entry("Cooles Gadget (Anzeige)"),
            entry("Immer wieder sonntags KW 24"),
            entry("Echte News"),
        ], page: "<div class=\"entry-inner\"><p>x</p></div>", options: CaschysBlogOptions(), store: tempStore())
        let titles = try await agg.aggregate().map(\.title)
        #expect(titles == ["Echte News"])
    }

    @Test func identifierChoicesHasSingleFeed() {
        #expect(CaschysBlogAggregator.identifierChoices.count == 1)
        #expect(CaschysBlogAggregator.identifierChoices.first?.value == "https://stadt-bremerhaven.de/feed/")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/CaschysBlogAggregatorTests`
Expected: FAIL — `cannot find 'CaschysBlogAggregator' in scope`.

- [ ] **Step 3: Implement `CaschysBlogAggregator`**

Create `Yana/Aggregators/Concrete/CaschysBlogAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Caschy's Blog (stadt-bremerhaven.de). Ports core/aggregators/caschys_blog/aggregator.py:
/// `.entry-inner` content, `.aawp*` removal, ad/recap skips, iframe whitelist, relative-URL
/// resolution, first-image dedup. Single feed.
final class CaschysBlogAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://stadt-bremerhaven.de/feed/"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://stadt-bremerhaven.de/feed/", "Caschy's Blog (Main Feed)"),
    ]

    var caschyOptions: CaschysBlogOptions {
        if case .caschysBlog(let o) = config.options { return o }
        return CaschysBlogOptions()
    }

    override var contentSelector: String { ".entry-inner" }

    override var selectorsToRemove: [String] {
        [".aawp", ".aawp-disclaimer", "script", "style", "noscript", "svg"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    override func shouldInclude(_ article: AggregatedArticle) -> Bool {
        let title = article.title
        if caschyOptions.skipAds, title.contains("(Anzeige)") { return false }
        if title.contains("Immer wieder sonntags KW") { return false }
        return true
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        let base = URL(string: article.url)

        // Iframe whitelist: keep only YouTube + Twitter/X; remove the rest.
        for iframe in try doc.select("iframe") {
            let src = try iframe.attr("src")
            let isYouTube = src.contains("youtube.com") || src.contains("youtu.be")
            let isTwitter = src.contains("twitter.com") || src.contains("x.com")
            if src.isEmpty || !(isYouTube || isTwitter) { try iframe.remove() }
        }

        // Resolve relative URLs for images and links.
        for img in try doc.select("img") {
            let src = try img.attr("src")
            if !src.isEmpty, !src.hasPrefix("http://"), !src.hasPrefix("https://"), !src.hasPrefix("data:") {
                if let abs = URL(string: src, relativeTo: base)?.absoluteString { try img.attr("src", abs) }
            }
        }
        for a in try doc.select("a") {
            let href = try a.attr("href")
            if !href.isEmpty, !["http://", "https://", "mailto:", "tel:", "#"].contains(where: { href.hasPrefix($0) }) {
                if let abs = URL(string: href, relativeTo: base)?.absoluteString { try a.attr("href", abs) }
            }
        }

        // Dedup the first image when there is a header image.
        if header != nil { try removeFirstImage(doc) }

        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: base)
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }

    /// Remove a leading image (direct, in a paragraph, or inside a link) — duplicate of the header.
    private func removeFirstImage(_ doc: Document) throws {
        guard let body = doc.body() else { return }
        for element in body.children().array() {
            switch element.tagName() {
            case "img":
                try element.remove(); return
            case "p":
                for child in element.children().array() {
                    if child.tagName() == "img" { try child.remove(); return }
                    if child.tagName() == "a", let img = try child.select("img").first() {
                        _ = img; try child.remove(); return
                    }
                    if child.tagName() == "br" { continue }
                    return
                }
                return
            default:
                return  // only inspect the first significant element
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/CaschysBlogAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/CaschysBlogAggregator.swift YanaTests/CaschysBlogAggregatorTests.swift
git commit -m "feat: CaschysBlogAggregator (.entry-inner, aawp/ad skips, iframe whitelist, image dedup)"
```

---

## Task 5: `MactechnewsAggregator`

Ports `core/aggregators/mactechnews/aggregator.py`: forced feed `mactechnews.de/Rss/News.x`,
`.MtnArticle` content, numeric-image-ID dedup (regex `\.(\d{5,})\.\w+$`), relative-URL
resolution. No user options.

**Files:**
- Create: `Yana/Aggregators/Concrete/MactechnewsAggregator.swift`
- Test: `YanaTests/MactechnewsAggregatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/MactechnewsAggregatorTests.swift`:

```swift
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
        // header image (og) Cover-X.592736.jpg; content has Bild.592736.jpg (same ID) + Other.111.jpg.
        let page = """
        <html><head><meta property="og:image" content="https://www.mactechnews.de/img/Cover-X.592736.jpg"></head>
        <body><div class="MtnArticle"><p>Body</p>\
        <img src="/img/Bild.592736.jpg">\
        <img src="/img/Other.111111.jpg"></div></body></html>
        """
        final class S: MactechnewsAggregator, @unchecked Sendable {
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
        let agg = S(page, tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Body"))
        #expect(!a.content.contains("592736"))           // duplicate numeric-ID image removed
        #expect(a.content.contains("111111") || a.content.contains("\(ReaderWeb.imageScheme)://"))  // other image kept/localized
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MactechnewsAggregatorTests`
Expected: FAIL — `cannot find 'MactechnewsAggregator' in scope`.

- [ ] **Step 3: Implement `MactechnewsAggregator`**

Create `Yana/Aggregators/Concrete/MactechnewsAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// MacTechNews (mactechnews.de). Ports core/aggregators/mactechnews/aggregator.py:
/// forced News feed, `.MtnArticle` content, numeric-image-ID dedup, relative-URL resolution.
final class MactechnewsAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let forcedFeed = "https://www.mactechnews.de/Rss/News.x"

    static let identifierChoices: [(value: String, label: String)] = []   // forced, no choices

    override var contentSelector: String { ".MtnArticle" }

    override var selectorsToRemove: [String] {
        [".NewsPictureMobile", "aside", "script", "style", "iframe", "noscript", "svg",
         "header", ".TexticonBox.Right"]
    }

    /// Overridable seam for tests to inject feed data.
    func fetchFeedData(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        return try await HTTPClient.fetchData(u).data
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let data = try await fetchFeedData(Self.forcedFeed)   // identifier is ignored — feed forced
        return try FeedParser.parse(data).entries
    }

    /// The header image URL for dedup, normally discovered from the page's og:image.
    /// Overridable so tests can supply it directly.
    func makeHeaderImageURL(forPage html: String) -> String? {
        guard let doc = try? HTMLUtils.parse(html),
              let meta = try? doc.select("meta[property=og:image]").first(),
              let content = try? meta.attr("content"), !content.isEmpty else { return nil }
        return content
    }

    static func extractImageID(_ url: String) -> String? {
        guard let r = url.range(of: #"\.(\d{5,})\.\w+$"#, options: .regularExpression) else { return nil }
        let match = String(url[r])
        if let idRange = match.range(of: #"\d{5,}"#, options: .regularExpression) {
            return String(match[idRange])
        }
        return nil
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        let base = URL(string: article.url)

        // Numeric-image-ID dedup against the header image.
        if let headerURL = makeHeaderImageURL(forPage: article.rawContent),
           let headerID = Self.extractImageID(headerURL) {
            for img in try doc.select("img") {
                let src = try img.attr("src")
                if !src.isEmpty, Self.extractImageID(src) == headerID { try img.remove() }
            }
        }

        // Resolve relative URLs.
        for img in try doc.select("img") {
            let src = try img.attr("src")
            if !src.isEmpty, !src.hasPrefix("http://"), !src.hasPrefix("https://"), !src.hasPrefix("data:") {
                if let abs = URL(string: src, relativeTo: base)?.absoluteString { try img.attr("src", abs) }
            }
        }
        for a in try doc.select("a") {
            let href = try a.attr("href")
            if !href.isEmpty, !["http://", "https://", "mailto:", "tel:", "#"].contains(where: { href.hasPrefix($0) }) {
                if let abs = URL(string: href, relativeTo: base)?.absoluteString { try a.attr("href", abs) }
            }
        }

        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: base)
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MactechnewsAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/MactechnewsAggregator.swift YanaTests/MactechnewsAggregatorTests.swift
git commit -m "feat: MactechnewsAggregator (forced feed, MtnArticle, numeric-ID dedup)"
```

---

## Task 6: `MeinMmoAggregator`

Ports `core/aggregators/mein_mmo/`: page-combining (`combinePages`) via pagination detection +
merging `div.gp-entry-content`, embed-processor strategies (YouTube / Twitter / Reddit / TikTok /
YouTube-fallback), Dailymotion block → `EmbedRewriter.dailymotionEmbedHTML`, pagination-marker
removal ("Weiter geht es auf Seite"), recirculation/affiliate removal. Single feed.

**Files:**
- Create: `Yana/Aggregators/Concrete/MeinMmoAggregator.swift`
- Test: `YanaTests/MeinMmoAggregatorTests.swift`

- [ ] **Step 1: Write the failing test (inject first page + extra pages)**

Create `YanaTests/MeinMmoAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("MeinMmoAggregator")
struct MeinMmoAggregatorTests {
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

    final class StubMmo: MeinMmoAggregator, @unchecked Sendable {
        let first: String; let extraPages: [String: String]
        init(first: String, extraPages: [String: String], options: MeinMmoOptions, store: ImageStore) {
            self.first = first; self.extraPages = extraPages
            super.init(config: FeedConfig(type: .meinMmo, identifier: "https://mein-mmo.de/feed/",
                                          dailyLimit: 20, options: .meinMmo(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { [] }   // not used; aggregate() drives enrich directly
        override func fetchArticleHTML(_ url: String) async throws -> String { first }
        override func fetchAdditionalPage(_ url: String) async throws -> String { extraPages[url] ?? "" }
    }

    /// Drives a single article through enrich() with injected pages.
    private func enrichOne(_ agg: MeinMmoAggregator) async throws -> AggregatedArticle {
        let base = agg.makeArticle(from: entry())
        return try await agg.enrich(base, entry: entry())
    }

    @Test func combinesPagesAndMergesContent() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Page one body</p>\
        <div class="gp-pagination-numbers"><a class="page-numbers" href="https://mein-mmo.de/post-1/2/">2</a></div>\
        </div></body></html>
        """
        let page2 = "<html><body><div class=\"gp-entry-content\"><p>Page two body</p></div></body></html>"
        let agg = StubMmo(first: first, extraPages: ["https://mein-mmo.de/post-1/2/": page2],
                          options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Page one body"))
        #expect(a.content.contains("Page two body"))
    }

    @Test func disablingCombineKeepsFirstPageOnly() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Only page one</p>\
        <div class="gp-pagination-numbers"><a class="page-numbers" href="https://mein-mmo.de/post-1/2/">2</a></div>\
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: ["https://mein-mmo.de/post-1/2/": "<div class=\"gp-entry-content\"><p>Page two</p></div>"],
                          options: { var o = MeinMmoOptions(); o.combinePages = false; return o }(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Only page one"))
        #expect(!a.content.contains("Page two"))
    }

    @Test func convertsDailymotionBlockAndRemovesPaginationMarkers() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Intro</p>\
        <div class="wp-block-mmo-video"><script>var x = { dmVideoId: 'x9yt07o' };</script></div>\
        <p><em>Weiter geht es auf Seite 2.</em></p>\
        <div class="wp-block-mmo-recirculation-box">related junk</div>\
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("dailymotion-embed-container"))
        #expect(a.content.contains("geo.dailymotion.com/player.html?video=x9yt07o"))
        #expect(!a.content.contains("Weiter geht es auf Seite"))
        #expect(!a.content.contains("related junk"))
    }

    @Test func convertsYouTubeFigureEmbed() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Intro</p>\
        <figure class="wp-block-embed-youtube"><a href="https://www.youtube.com/watch?v=abc12345678">link</a></figure>\
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("youtube-nocookie.com/embed/abc12345678"))
    }

    @Test func identifierChoicesHasSingleFeed() {
        #expect(MeinMmoAggregator.identifierChoices.count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MeinMmoAggregatorTests`
Expected: FAIL — `cannot find 'MeinMmoAggregator' in scope`.

- [ ] **Step 3: Implement `MeinMmoAggregator`**

Create `Yana/Aggregators/Concrete/MeinMmoAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Mein-MMO.de gaming news. Ports core/aggregators/mein_mmo/: page-combining, embed strategies
/// (YouTube/Twitter/Reddit/TikTok), Dailymotion conversion, pagination-marker + recirculation removal.
final class MeinMmoAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://mein-mmo.de/feed/"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://mein-mmo.de/feed/", "Main Feed (All Articles)"),
    ]

    var meinMmoOptions: MeinMmoOptions {
        if case .meinMmo(let o) = config.options { return o }
        return MeinMmoOptions()
    }

    override var contentSelector: String { "div.gp-entry-content" }

    override var selectorsToRemove: [String] {
        ["div.wp-block-mmo-recirculation-box", "div.reading-position-indicator-end",
         "label.toggle", "a.wp-block-mmo-content-box", "ul.page-numbers", ".post-page-numbers",
         "#ftwp-container-outer", "div.wp-block-wbd-affiliate-widget", "script", "style",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])", "noscript"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    /// Overridable seam: fetch an additional page of a multi-page article.
    func fetchAdditionalPage(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw AggregatorError.contentFetch("bad page url") }
        return try await HTTPClient.fetchHTML(u)
    }

    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        do {
            let first = try await fetchArticleHTML(article.url)
            article.rawContent = first

            // Combine pages if enabled and pagination detected.
            var contentDivs: [String] = extractContentDivHTML(from: first).map { [$0] } ?? []
            if meinMmoOptions.combinePages {
                let pages = detectPagination(html: first)
                if pages.count > 1 {
                    contentDivs = []
                    for page in pages.sorted() {
                        let pageURL = page == 1 ? article.url : pageURLFor(base: article.url, page: page)
                        let html = page == 1 ? first : ((try? await fetchAdditionalPage(pageURL)) ?? "")
                        if let div = extractContentDivHTML(from: html) { contentDivs.append(div) }
                    }
                }
            }
            let merged = mergeContentDivs(contentDivs)
            let processed = try await processMeinMmoContent(merged, article: article)
            article.content = processed
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }
            return article
        } catch {
            return article
        }
    }

    // MARK: - Pagination

    func detectPagination(html: String) -> Set<Int> {
        var pages: Set<Int> = [1]
        guard let doc = try? HTMLUtils.parse(html) else { return pages }
        let contentDiv = try? doc.select("div.gp-entry-content").first()
        let container = (try? contentDiv?.select("div.gp-pagination-numbers, ul.page-numbers, nav.navigation.pagination, div.gp-pagination").first()) ?? nil
            ?? (try? doc.select("div.gp-pagination-numbers, nav.navigation.pagination, div.gp-pagination, ul.page-numbers").first()) ?? nil
        guard let pagination = container else { return pages }
        for link in (try? pagination.select("a.page-numbers, a.post-page-numbers").array()) ?? [] {
            if let text = try? link.text(), let n = Int(text) { pages.insert(n) }
            if let href = try? link.attr("href"),
               let r = href.range(of: #"/(\d+)/?$"#, options: .regularExpression),
               let n = Int(href[r].filter(\.isNumber)) { pages.insert(n) }
        }
        for span in (try? pagination.select("span.page-numbers, span.post-page-numbers, span.current").array()) ?? [] {
            if let text = try? span.text(), let n = Int(text) { pages.insert(n) }
        }
        return pages
    }

    private func pageURLFor(base: String, page: Int) -> String {
        base.hasSuffix("/") ? "\(base)\(page)/" : "\(base)/\(page)/"
    }

    private func extractContentDivHTML(from html: String) -> String? {
        guard let doc = try? HTMLUtils.parse(html),
              let div = try? doc.select("div.gp-entry-content").first() else { return nil }
        return try? div.html()
    }

    private func mergeContentDivs(_ divs: [String]) -> String {
        "<div class=\"gp-entry-content\">\(divs.joined(separator: "\n\n"))</div>"
    }

    // MARK: - Content processing

    func processMeinMmoContent(_ html: String, article: AggregatedArticle) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        guard let content = try doc.select("div.gp-entry-content").first() ?? doc.body() else {
            return ""
        }

        // Dailymotion blocks → direct embed (before removal selectors strip leftovers).
        try convertDailymotionBlocks(content)

        // Remove unwanted elements.
        for selector in selectorsToRemove {
            for el in try content.select(selector) { try el.remove() }
        }

        // Remove "Weiter geht es auf Seite" pagination markers.
        for em in try content.select("em") {
            if try em.text().contains("Weiter geht es auf Seite") {
                if let p = em.parent(), p.tagName() == "p" { try p.remove() } else { try em.remove() }
            }
        }

        // Embed-processor strategies on <figure>.
        try processEmbedFigures(content)

        try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div"])
        try EmbedRewriter.rewriteEmbeds(in: doc)   // normalize any remaining YouTube iframes
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: nil, commentsHTML: nil)
    }

    private func convertDailymotionBlocks(_ content: Element) throws {
        for block in try content.select("div.wp-block-mmo-video") {
            guard let id = dailymotionVideoID(block) else { continue }
            let title = (try? block.select("div.title").first()?.text()) ?? nil
            var html = EmbedRewriter.dailymotionEmbedHTML(videoID: id)
            if let title, !title.isEmpty {
                // Append caption inside the container.
                html = html.replacingOccurrences(of: "</div>", with: "<p>\(title)</p></div>")
            }
            let fragment = try SwiftSoup.parseBodyFragment(html)
            if let replacement = fragment.body()?.child(0) { try block.replaceWith(replacement) }
        }
    }

    private func dailymotionVideoID(_ block: Element) -> String? {
        for script in (try? block.select("script").array()) ?? [] {
            let text = (try? script.html()) ?? ""
            if let r = text.range(of: #"dmVideoId:\s*'([^']+)'"#, options: .regularExpression) {
                let match = String(text[r])
                if let idRange = match.range(of: #"'([^']+)'"#, options: .regularExpression) {
                    return String(match[idRange]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                }
            }
        }
        return nil
    }

    /// Strategy chain over <figure>: YouTube (class/link) → Twitter → Reddit → TikTok → YouTube-link fallback.
    private func processEmbedFigures(_ content: Element) throws {
        for figure in try content.select("figure").array() {
            let classStr = ((try? figure.classNames()) ?? []).joined(separator: " ")
            if classStr.contains("youtube") || classStr.contains("is-provider-youtube") {
                if let id = youTubeIDInFigure(figure) {
                    try figure.replaceWith(parse(EmbedRewriter.youTubeEmbedHTML(videoID: id))); continue
                }
            }
            if let twitter = linkMatching(figure, hosts: ["twitter.com", "x.com"]) {
                let clean = twitter.split(separator: "?").first.map(String.init) ?? twitter
                try figure.replaceWith(parse("<p><a href=\"\(clean)\" target=\"_blank\" rel=\"noopener\">View on X/Twitter: \(clean)</a></p>")); continue
            }
            if classStr.contains("provider-reddit") || classStr.contains("embed-reddit"),
               let reddit = linkMatching(figure, hosts: ["reddit.com"]) {
                let clean = reddit.split(separator: "?").first.map(String.init) ?? reddit
                try figure.replaceWith(parse("<p><a href=\"\(clean)\" target=\"_blank\" rel=\"noopener\">View on Reddit</a></p>")); continue
            }
            if classStr.contains("tiktok"), let tiktok = linkMatching(figure, hosts: ["tiktok.com"]),
               let r = tiktok.range(of: #"/video/(\d+)"#, options: .regularExpression) {
                let id = String(tiktok[r]).filter(\.isNumber)
                try figure.replaceWith(parse("<div data-sanitized-class=\"tiktok-embed\"><iframe src=\"https://www.tiktok.com/embed/v3/\(id)\" width=\"325\" height=\"605\" allowfullscreen allow=\"autoplay; encrypted-media\"></iframe></div>")); continue
            }
            // Fallback: any YouTube link.
            if let id = youTubeIDInFigure(figure) {
                try figure.replaceWith(parse(EmbedRewriter.youTubeEmbedHTML(videoID: id)))
            }
        }
    }

    private func youTubeIDInFigure(_ figure: Element) -> String? {
        for link in (try? figure.select("a[href]").array()) ?? [] {
            if let href = try? link.attr("href"), let id = EmbedRewriter.extractYouTubeID(from: href) { return id }
        }
        return nil
    }

    private func linkMatching(_ figure: Element, hosts: [String]) -> String? {
        for link in (try? figure.select("a[href]").array()) ?? [] {
            if let href = try? link.attr("href"), hosts.contains(where: { href.contains($0) }) { return href }
        }
        return nil
    }

    private func parse(_ html: String) -> Element {
        (try? SwiftSoup.parseBodyFragment(html).body()?.child(0)) ?? (try! SwiftSoup.parse("<span></span>").body()!.child(0))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/MeinMmoAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/MeinMmoAggregator.swift YanaTests/MeinMmoAggregatorTests.swift
git commit -m "feat: MeinMmoAggregator (page-combining, embed strategies, Dailymotion)"
```

---

## Task 7: Register the six scrapers

**Files:**
- Modify: `Yana/Aggregators/AggregatorRegistry.swift`
- Test: `YanaTests/AggregatorRegistryScrapersTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregatorRegistryScrapersTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry — scrapers")
struct AggregatorRegistryScrapersTests {
    private func cfg(_ type: AggregatorType, _ options: AggregatorOptions) -> FeedConfig {
        FeedConfig(type: type, identifier: "x", dailyLimit: 20, options: options, collectedToday: 0)
    }

    @Test func buildsEachScraperType() {
        let r = AggregatorRegistry.shared
        #expect(r.makeAggregator(cfg(.heise, .heise(HeiseOptions())), credentials: .init()) is HeiseAggregator)
        #expect(r.makeAggregator(cfg(.merkur, .merkur(MerkurOptions())), credentials: .init()) is MerkurAggregator)
        #expect(r.makeAggregator(cfg(.tagesschau, .tagesschau(TagesschauOptions())), credentials: .init()) is TagesschauAggregator)
        #expect(r.makeAggregator(cfg(.caschysBlog, .caschysBlog(CaschysBlogOptions())), credentials: .init()) is CaschysBlogAggregator)
        #expect(r.makeAggregator(cfg(.mactechnews, .mactechnews(MactechnewsOptions())), credentials: .init()) is MactechnewsAggregator)
        #expect(r.makeAggregator(cfg(.meinMmo, .meinMmo(MeinMmoOptions())), credentials: .init()) is MeinMmoAggregator)
    }

    @Test func unregisteredStillNil() {
        #expect(AggregatorRegistry.shared.makeAggregator(
            cfg(.reddit, .reddit(RedditOptions())), credentials: .init()) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregatorRegistryScrapersTests`
Expected: FAIL — the scraper cases return `nil` (registry only knows feedContent/fullWebsite).

- [ ] **Step 3: Add the cases to `makeAggregator`**

In `Yana/Aggregators/AggregatorRegistry.swift`, add the six cases to the `switch` (keep the
existing `feedContent` / `fullWebsite` cases and the `default`):

```swift
    func makeAggregator(_ config: FeedConfig, credentials: AggregatorCredentials) -> (any Aggregator)? {
        switch config.type {
        case .feedContent: return FeedContentAggregator(config: config, credentials: credentials)
        case .fullWebsite: return FullWebsiteAggregator(config: config, credentials: credentials)
        case .heise: return HeiseAggregator(config: config, credentials: credentials)
        case .merkur: return MerkurAggregator(config: config, credentials: credentials)
        case .tagesschau: return TagesschauAggregator(config: config, credentials: credentials)
        case .caschysBlog: return CaschysBlogAggregator(config: config, credentials: credentials)
        case .mactechnews: return MactechnewsAggregator(config: config, credentials: credentials)
        case .meinMmo: return MeinMmoAggregator(config: config, credentials: credentials)
        // 4e social/media (reddit, youtube, podcast) and the remaining comic scrapers add their cases here.
        default: return nil
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregatorRegistryScrapersTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS (no regressions in 4a–4c suites).

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/AggregatorRegistry.swift YanaTests/AggregatorRegistryScrapersTests.swift
git commit -m "feat: register six site scrapers in AggregatorRegistry"
```

---

## Task 8: Predefined-feed Picker in `FeedEditorView`

When the selected aggregator type exposes predefined RSS-feed choices, the editor should let the
user pick from a labeled list (instead of, or in addition to, typing a raw URL). This task adds a
single `identifierChoices(for:)` lookup keyed on `AggregatorType` and renders a Picker when choices
exist, matching the existing `Picker("Type", ...)` style.

**Files:**
- Modify: `Yana/Views/Config/FeedEditorView.swift`
- Test: `YanaTests/FeedIdentifierChoicesTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/FeedIdentifierChoicesTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("Feed identifier choices")
struct FeedIdentifierChoicesTests {
    @Test func choicesForScraperTypes() {
        #expect(AggregatorType.heise.identifierChoices.count == 4)
        #expect(AggregatorType.merkur.identifierChoices.count == 18)
        #expect(AggregatorType.tagesschau.identifierChoices.count == 42)
        #expect(AggregatorType.caschysBlog.identifierChoices.count == 1)
        #expect(AggregatorType.meinMmo.identifierChoices.count == 1)
    }

    @Test func noChoicesForForcedOrGenericTypes() {
        #expect(AggregatorType.mactechnews.identifierChoices.isEmpty)   // forced feed
        #expect(AggregatorType.fullWebsite.identifierChoices.isEmpty)
        #expect(AggregatorType.feedContent.identifierChoices.isEmpty)
        #expect(AggregatorType.reddit.identifierChoices.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedIdentifierChoicesTests`
Expected: FAIL — `value of type 'AggregatorType' has no member 'identifierChoices'`.

- [ ] **Step 3: Add `identifierChoices` to `AggregatorType`**

In `Yana/Aggregators/AggregatorType.swift`, add a computed property that maps each type to its
scraper's static choices (returning `[]` where there are none):

```swift
    /// Predefined RSS-feed choices for the feed editor's identifier Picker (empty = free-form URL or forced feed).
    var identifierChoices: [(value: String, label: String)] {
        switch self {
        case .heise: HeiseAggregator.identifierChoices
        case .merkur: MerkurAggregator.identifierChoices
        case .tagesschau: TagesschauAggregator.identifierChoices
        case .caschysBlog: CaschysBlogAggregator.identifierChoices
        case .meinMmo: MeinMmoAggregator.identifierChoices
        default: []
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedIdentifierChoicesTests`
Expected: PASS.

- [ ] **Step 5: Render the Picker in `FeedEditorView`**

In `Yana/Views/Config/FeedEditorView.swift`, replace the identifier `TextField` block inside the
`Section("Feed")` with a Picker when the type has predefined choices, falling back to the existing
free-form `TextField` otherwise. The choices include a "Custom URL…" sentinel so a user can still
type a non-listed feed:

```swift
                if !model.type.identifierChoices.isEmpty {
                    Picker("Feed", selection: $model.identifier) {
                        ForEach(model.type.identifierChoices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                } else if model.type.identifierKind != .none {
                    TextField(identifierLabel, text: $model.identifier)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
```

When the user switches to a type with choices and the current `identifier` is empty or not in the
list, default it to the first choice. In `FeedEditorModel.changeType(_:)`, after resetting options,
seed the identifier from the first predefined choice if any:

```swift
    func changeType(_ newType: AggregatorType) {
        type = newType
        options = newType.defaultOptions
        if let first = newType.identifierChoices.first,
           !newType.identifierChoices.contains(where: { $0.value == identifier }) {
            identifier = first.value
        }
    }
```

- [ ] **Step 6: Build + run the full suite to verify the view compiles and nothing regressed**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.
Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Yana/Aggregators/AggregatorType.swift Yana/Views/Config/FeedEditorView.swift Yana/Views/Config/FeedEditorModel.swift YanaTests/FeedIdentifierChoicesTests.swift
git commit -m "feat: predefined RSS-feed Picker in feed editor"
```

---

## Notes for later phases (not part of 4d)

- **Remaining managed scrapers** (`explosm`, `darkLegacy`, `oglaf` — comic image scrapers) are
  not part of 4d (they are image/comic-oriented, not `FullWebsiteAggregator` HTML extractors) and
  are scheduled with the media family or a dedicated comic-scraper plan.
- **`update(article:)` single-article re-fetch:** scrapers inherit the 4c `enrich` path; the
  service still re-runs the owning feed (4a note) until the per-article re-fetch lands.
- **AI post-processing** (4f) hooks into `finalize`, which every scraper inherits unchanged.

---

## Self-Review

**Spec coverage (§4.2):**
- **Heise** (T1): `seite=all` multi-page URL, `#meldung, .StoryContent`, full remove-list, title
  skip-list via `shouldInclude`, "Event Sourcing" via `postFilter`, empty-element removal, forum
  comments (JSON-LD `discussionUrl` → fallback link → `li.posting_element`/`[id^=posting_]`/`.posting`/`.a-comment`)
  as blockquotes capped at `maxComments`, gated by `includeComments`, passed as `commentsHTML`, 4 feeds.
- **Merkur** (T2): `.idjs-Story`, full remove-list, optional `removeEmptyElements`, 18 regional feeds.
- **Tagesschau** (T3): textabsatz/trenner extraction skipping teaser/bigfive/accordion/related,
  MediaPlayer media header (audio/video, poster, entity-decoded `data-v` JSON), livestream/podcast
  title skips + video/blickpunkte URL skips, 42 feeds.
- **Caschy** (T4): `.entry-inner`, `.aawp*` removal, "(Anzeige)"/"Immer wieder sonntags KW" skips,
  iframe whitelist (YouTube+Twitter), relative-URL resolution, first-image dedup, single feed.
- **MacTechNews** (T5): forced `mactechnews.de/Rss/News.x`, `.MtnArticle`, numeric-image-ID dedup
  (`\.(\d{5,})\.\w+$`), relative-URL resolution, no options.
- **Mein-MMO** (T6): page-combining via pagination detection + merge `div.gp-entry-content`,
  embed strategies (YouTube/Twitter/Reddit/TikTok/YouTube-fallback), Dailymotion block →
  `EmbedRewriter.dailymotionEmbedHTML`, "Weiter geht es auf Seite" + recirculation/affiliate removal,
  single feed.
- **Registry** (T7) and **editor Picker** (T8).

**Placeholders:** none — every step has complete Swift (tests + implementation) or an exact
command + expected output.

**Type consistency:** every scraper uses the 4c base-class hooks verbatim (`fetchEntries`,
`contentSelector`, `selectorsToRemove`, `shouldInclude`, `postFilter`, `enrich`, `processContent`,
`processFullContent`, `fetchArticleHTML`, `finalize`) and the 4b utilities (`HTTPClient.fetchData`/`fetchHTML`,
`FeedParser.parse`, `HTMLUtils.*`, `EmbedRewriter.youTubeEmbedHTML`/`dailymotionEmbedHTML`/`rewriteEmbeds`/`extractYouTubeID`,
`rewriteImages`, `ContentFormatter.format`, `ReaderWeb.imageScheme`, `HeaderElement`). Options are read
through per-scraper accessors that pattern-match the correct `AggregatorOptions` case using the exact
field names from `Yana/Models/AggregatorOptions.swift` (`HeiseOptions.includeComments`/`.maxComments`,
`MerkurOptions.removeEmptyElements`, `TagesschauOptions.skipLivestreams`/`.skipVideos`,
`CaschysBlogOptions.skipAds`, `MactechnewsOptions` field-free path, `MeinMmoOptions.combinePages`).
Registry cases align with `AggregatorType` raw cases; tests inject fixtures by subclassing
`fetchEntries`/`fetchArticleHTML`/`fetchCommentsHTML`/`fetchAdditionalPage`/`fetchFeedData`/`makeHeaderImageURL`
with inline HTML — no live network. `ImageStore` is injected via the temp-store helper from the 4c tests.

**Fidelity risks flagged:**
1. **Tagesschau `identifierChoices`.** Ported verbatim from the server
   (`core/aggregators/tagesschau/aggregator.py`): exactly **42** feeds (1 "Alle Meldungen" +
   41 sections). No fabricated/padded URLs. If the server's list changes, re-sync from source.
2. **Heise comment "full view" anchor.** The server builds `comment_url = f"{article_url}#{comment_id}"`;
   the port emits `#<id>` as a relative anchor (the article URL is already the page). Equivalent in
   the reader; flagged in case absolute URLs are preferred.
3. **Mein-MMO `detectPagination` chained optional `select` fallback.** The double `?? nil` coalescing
   for the content-div-scoped vs. global pagination container is correct but brittle Swift; if SwiftSoup's
   `select().first()` typing changes, simplify to explicit `if let`. Behavior matches the server's
   "content-div first, then global" precedence.
4. **`processFullContent` vs. `processContent` override point.** Scrapers override `processFullContent`
   (the 4c full-page path) rather than `processContent` (the RSS-only path). This relies on 4c's
   `FullWebsiteAggregator.enrich` calling `processFullContent` when `useFullContent` is true. Confirmed
   against the 4c plan; if 4c renamed that hook, update the override name across all six scrapers.
5. **og:image discovery for MacTechNews dedup.** The server's header image comes from the
   `HeaderElementExtractor` (4b) which defers full-page `og:image` discovery to 4c. The port adds a
   `makeHeaderImageURL(forPage:)` reading `meta[property=og:image]` from the already-fetched page so
   numeric-ID dedup works even if the 4c header extractor returns nil; verify it does not double-count
   with the 4c header element.
