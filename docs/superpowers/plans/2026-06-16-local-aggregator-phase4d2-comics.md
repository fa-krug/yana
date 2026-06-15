# Phase 4d2 — Web-Comic Aggregators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the three fixed-source web-comic aggregators — Explosm (Cyanide & Happiness), Dark Legacy Comics, and Oglaf — each as a `FullWebsiteAggregator` subclass that locates the comic image(s), shows alt/title text, and localizes images.

**Architecture:** Each comic has a hardcoded RSS feed and a single article layout. They subclass `FullWebsiteAggregator` (4c), set a fixed `fetchEntries()` source, and override the per-article enrichment to extract the comic `<img>` from the page, append the alt/title caption, and run it through the shared image pipeline (so the comic image is downloaded and served via `yana-img://`, per decision 3). Header-element extraction is disabled for comics (the comic image *is* the content). Tests inject the feed entries + page HTML and an in-memory `ImageStore` — no live network.

**Tech Stack:** Swift 6, SwiftSoup, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-16-local-aggregator-phase4-design.md` (§4.2, comics row; decision 3).

**Depends on:** 4a, 4b, 4c (`FullWebsiteAggregator`, `HTMLUtils`, `ContentFormatter`, `rewriteImages`, `ImageStore`).

**Reference (port faithfully):** `/Users/skrug/PycharmProjects/Yana/core/aggregators/{explosm,dark_legacy,oglaf}/`.

---

## Note on `convertToBase64` (Oglaf)

The server's `OglafOptions.convertToBase64` chose between base64-inlining vs. a remote image URL.
Under spec decision 3, **all images are downloaded and localized** (`yana-img://`) regardless, so
this option no longer changes behavior. It is retained in the model for parity; the aggregator
localizes the comic image either way. (`showAltText` is fully honored.)

## File Structure

- Create `Yana/Aggregators/Concrete/ComicAggregator.swift` — shared `ComicAggregator` base (fixed feed + comic-image enrichment) + the three subclasses.
- Modify `Yana/Aggregators/AggregatorRegistry.swift` — add `.explosm` / `.darkLegacy` / `.oglaf` cases.
- Modify `Yana/Aggregators/AggregatorType.swift` — comics have no predefined identifier choices (fixed source); no `identifierChoices` entries needed.
- Test: `YanaTests/ComicAggregatorTests.swift`.

Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`

---

## Task 1: `ComicAggregator` base + Explosm

**Files:**
- Create: `Yana/Aggregators/Concrete/ComicAggregator.swift`
- Test: `YanaTests/ComicAggregatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ComicAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("ComicAggregator")
struct ComicAggregatorTests {
    func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    func entry(_ link: String) -> FeedEntry {
        FeedEntry(title: "Comic", link: link, content: "", summary: "", entryDescription: "",
                  published: .now, author: "", enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubExplosm: ExplosmAggregator, @unchecked Sendable {
        let page: String
        init(page: String, store: ImageStore) {
            self.page = page
            super.init(config: FeedConfig(type: .explosm, identifier: "", dailyLimit: 20,
                                          options: .explosm(ExplosmOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { [ComicAggregatorTests().entry("https://explosm.net/comics/1")] }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func explosmExtractsComicImageAndAltText() async throws {
        let page = """
        <html><body><div id="comic">
          <img src="https://static.explosm.net/2025/12/12/strip.png" alt="The joke">
        </div></body></html>
        """
        let agg = StubExplosm(page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))     // image localized
        #expect(!a.content.contains("static.explosm.net"))             // no remote URL
        #expect(a.content.contains("The joke"))                         // alt caption shown
        #expect(a.content.contains("Source:"))                          // footer
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ComicAggregatorTests`
Expected: FAIL — `cannot find 'ExplosmAggregator' in scope`.

- [ ] **Step 3: Implement the base + Explosm**

Create `Yana/Aggregators/Concrete/ComicAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Base for fixed-source web comics: a hardcoded feed, single comic image per article,
/// optional alt/title caption, image localized via the shared pipeline. Header disabled.
class ComicAggregator: FullWebsiteAggregator, @unchecked Sendable {
    /// The hardcoded RSS feed for this comic.
    var feedURL: String { "" }
    /// CSS selector for the comic container.
    override var contentSelector: String { "body" }
    /// Whether to show alt text below the image (subclasses read their own options).
    var showAltText: Bool { true }

    override func fetchEntries() async throws -> [FeedEntry] {
        guard let url = URL(string: feedURL) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(url)
        return try FeedParser.parse(data).entries
    }

    override func validate() throws {}   // fixed source; no user identifier required

    /// Comics ignore the generic header element; they build content from the comic image.
    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        let raw = try await fetchArticleHTML(article.url)
        article.rawContent = raw
        let comicHTML = try buildComicHTML(pageHTML: raw, article: article)
        // Localize images + wrap. (rewriteImages downloads the comic image → yana-img://.)
        let doc = try HTMLUtils.parse(comicHTML)
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        let body = try HTMLUtils.bodyHTML(doc)
        article.content = ContentFormatter.format(content: body, title: article.title, url: article.url,
                                                  headerHTML: nil, commentsHTML: nil)
        return article
    }

    /// Subclasses override to locate the comic image(s) and produce the inner HTML.
    func buildComicHTML(pageHTML: String, article: AggregatedArticle) throws -> String {
        let extracted = try HTMLUtils.extractMainContent(pageHTML, selector: contentSelector, removeSelectors: [])
        return extracted
    }

    /// Shared caption markup (mirrors the server's italic caption).
    func captionHTML(_ text: String) -> String {
        guard showAltText, !text.isEmpty else { return "" }
        let safe = text.replacingOccurrences(of: "<", with: "&lt;")
        return "<p style=\"font-style: italic; margin-top: 1em; color: #666; text-align: center;\">\(safe)</p>"
    }
}

/// Cyanide & Happiness. Feed https://explosm.net/rss.xml; image src contains static.explosm.net.
class ExplosmAggregator: ComicAggregator, @unchecked Sendable {
    override var feedURL: String { "https://explosm.net/rss.xml" }
    override var contentSelector: String { "#comic" }
    override var showAltText: Bool {
        if case .explosm(let o) = config.options { return o.showAltText }
        return true
    }

    override func buildComicHTML(pageHTML: String, article: AggregatedArticle) throws -> String {
        let doc = try HTMLUtils.parse(pageHTML)
        let img = try doc.select("img").first { try $0.attr("src").contains("static.explosm.net") }
        guard let img, let src = try? img.attr("src") else { return "" }
        let alt = (try? img.attr("alt")) ?? ""
        return "<div style=\"text-align: center;\"><img src=\"\(src)\" alt=\"\(alt.replacingOccurrences(of: "\"", with: "&quot;"))\">\(captionHTML(alt))</div>"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ComicAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/ComicAggregator.swift YanaTests/ComicAggregatorTests.swift
git commit -m "feat: ComicAggregator base + Explosm"
```

---

## Task 2: Dark Legacy + Oglaf

**Files:**
- Modify: `Yana/Aggregators/Concrete/ComicAggregator.swift`
- Modify: `YanaTests/ComicAggregatorTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `ComicAggregatorTests` (inside the suite struct):

```swift
    final class StubDarkLegacy: DarkLegacyAggregator, @unchecked Sendable {
        let page: String
        init(page: String, store: ImageStore) {
            self.page = page
            super.init(config: FeedConfig(type: .darkLegacy, identifier: "", dailyLimit: 20,
                                          options: .darkLegacy(DarkLegacyOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { [ComicAggregatorTests().entry("https://darklegacycomics.com/172")] }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func darkLegacyResolvesRelativeImageURLs() async throws {
        let page = "<html><body><div id=\"gallery\"><img src=\"/images/172.png\" alt=\"DL\"></div></body></html>"
        let agg = StubDarkLegacy(page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))
        #expect(a.content.contains("DL"))
    }

    final class StubOglaf: OglafAggregator, @unchecked Sendable {
        let page: String
        init(page: String, store: ImageStore) {
            self.page = page
            super.init(config: FeedConfig(type: .oglaf, identifier: "", dailyLimit: 20,
                                          options: .oglaf(OglafOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { [ComicAggregatorTests().entry("https://www.oglaf.com/2025/")] }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func oglafShowsTitleJokeAsCaption() async throws {
        let page = "<html><body><div class=\"content\"><img id=\"strip\" src=\"https://media.oglaf.com/comic/x.jpg\" alt=\"alt\" title=\"the second joke\"></div></body></html>"
        let agg = StubOglaf(page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))
        #expect(a.content.contains("the second joke"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ComicAggregatorTests`
Expected: FAIL — `cannot find 'DarkLegacyAggregator' in scope`.

- [ ] **Step 3: Implement Dark Legacy + Oglaf**

Append to `Yana/Aggregators/Concrete/ComicAggregator.swift`:

```swift
/// Dark Legacy Comics. Feed https://darklegacycomics.com/feed.xml; container #gallery;
/// images may be relative → resolved against the article URL by rewriteImages.
class DarkLegacyAggregator: ComicAggregator, @unchecked Sendable {
    override var feedURL: String { "https://darklegacycomics.com/feed.xml" }
    override var contentSelector: String { "#gallery" }
    override var showAltText: Bool {
        if case .darkLegacy(let o) = config.options { return o.showAltText }
        return true
    }

    override func buildComicHTML(pageHTML: String, article: AggregatedArticle) throws -> String {
        let doc = try HTMLUtils.parse(pageHTML)
        let gallery = try doc.select(contentSelector).first() ?? doc.body() ?? doc
        var html = "<div style=\"text-align: center;\">"
        for img in try gallery.select("img") {
            let src = try img.attr("src")
            guard !src.isEmpty else { continue }
            let alt = (try? img.attr("alt")) ?? ""
            // Leave src as-is (may be relative); rewriteImages resolves against baseURL.
            html += "<img src=\"\(src)\" alt=\"\(alt.replacingOccurrences(of: "\"", with: "&quot;"))\">\(captionHTML(alt))"
        }
        html += "</div>"
        return html
    }
}

/// Oglaf (adult). Feed https://www.oglaf.com/feeds/rss/; image #strip (fallback .content img);
/// the <img title> holds a second joke shown as caption. Images localized regardless of
/// convertToBase64 (decision 3).
class OglafAggregator: ComicAggregator, @unchecked Sendable {
    override var feedURL: String { "https://www.oglaf.com/feeds/rss/" }
    override var contentSelector: String { "div.content" }
    override var showAltText: Bool {
        if case .oglaf(let o) = config.options { return o.showAltText }
        return true
    }

    override func buildComicHTML(pageHTML: String, article: AggregatedArticle) throws -> String {
        let doc = try HTMLUtils.parse(pageHTML)
        let img = try doc.select("#strip").first()
            ?? doc.select(".content img, #content img, .comic img").first()
        guard let img else { return "" }
        var src = try img.attr("src")
        if src.hasPrefix("/") {
            src = "https://www.oglaf.com" + src
        } else if !src.hasPrefix("http") && !src.contains("media.oglaf.com") {
            src = "https://media.oglaf.com/comic/" + src
        }
        let joke = (try? img.attr("title")) ?? ""
        return "<div style=\"text-align: center;\"><img src=\"\(src)\" alt=\"\(((try? img.attr("alt")) ?? "").replacingOccurrences(of: "\"", with: "&quot;"))\" style=\"max-width: 100%; height: auto;\">\(captionHTML(joke))</div>"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ComicAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Concrete/ComicAggregator.swift YanaTests/ComicAggregatorTests.swift
git commit -m "feat: Dark Legacy + Oglaf comic aggregators"
```

---

## Task 3: Register the comic aggregators

**Files:**
- Modify: `Yana/Aggregators/AggregatorRegistry.swift`
- Test: `YanaTests/AggregatorRegistryComicsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregatorRegistryComicsTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry — comics")
struct AggregatorRegistryComicsTests {
    private func cfg(_ type: AggregatorType, _ options: AggregatorOptions) -> FeedConfig {
        FeedConfig(type: type, identifier: "", dailyLimit: 20, options: options, collectedToday: 0)
    }

    @Test func buildsComicAggregators() {
        #expect(AggregatorRegistry.shared.makeAggregator(cfg(.explosm, .explosm(ExplosmOptions())), credentials: .init()) is ExplosmAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(cfg(.darkLegacy, .darkLegacy(DarkLegacyOptions())), credentials: .init()) is DarkLegacyAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(cfg(.oglaf, .oglaf(OglafOptions())), credentials: .init()) is OglafAggregator)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregatorRegistryComicsTests`
Expected: FAIL — registry returns `nil` for comic types.

- [ ] **Step 3: Add the cases**

In `Yana/Aggregators/AggregatorRegistry.swift`, add to the `makeAggregator` switch (alongside the existing cases, before `default`):

```swift
        case .explosm: return ExplosmAggregator(config: config, credentials: credentials)
        case .darkLegacy: return DarkLegacyAggregator(config: config, credentials: credentials)
        case .oglaf: return OglafAggregator(config: config, credentials: credentials)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregatorRegistryComicsTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/AggregatorRegistry.swift YanaTests/AggregatorRegistryComicsTests.swift
git commit -m "feat: register comic aggregators (explosm, darkLegacy, oglaf)"
```

---

## Self-Review

**Spec coverage (§4.2 comics):** Explosm (`#comic`, static.explosm.net image, `showAltText`),
Dark Legacy (`#gallery`, relative-URL resolution, `showAltText`), Oglaf (`#strip` fallback,
URL resolution, title-joke caption, `convertToBase64` noted as moot under decision 3). All three
localize images via the shared pipeline. Registered (T3). Covered.

**Placeholders:** none — complete code or exact command + expected in every step.

**Type consistency:** uses 4c (`FullWebsiteAggregator`, `fetchEntries`, `fetchArticleHTML`,
`enrich`, `contentSelector`), 4b (`HTMLUtils.parse/extractMainContent/bodyHTML`, `rewriteImages`,
`ContentFormatter.format`, `ReaderWeb.imageScheme`, `ImageStore`), 4a (`FeedConfig`,
`AggregatorError`, `AggregatorRegistry.makeAggregator`) verbatim. Option accessors match
`ExplosmOptions`/`DarkLegacyOptions`/`OglafOptions` in `AggregatorOptions.swift`.
