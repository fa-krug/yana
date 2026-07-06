# The Verge & Ars Technica Aggregators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two dedicated managed full-article scraper aggregator types — The Verge (`the_verge`) and Ars Technica (`ars_technica`) — to Yana's catalog.

**Architecture:** Both subclass `FullWebsiteAggregator` (which provides fetch → extract-by-CSS-selector → header-hoist → image-download → sanitize). The Verge is a plain single-block extractor modeled on `MerkurAggregator`. Ars overrides `enrich()` to merge **all** in-page `.post-content` blocks (multi-"page" features render every page in one fetch as sibling blocks; the base extraction keeps only the first, which truncates). Each new type is a vertical slice: options struct → aggregator class → `AggregatorType` case + metadata → registry wiring → options-form UI → tests.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, SwiftSoup (HTML parsing), Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- **Swift 6 strict concurrency**: aggregator classes are `@unchecked Sendable` (created per-run, not shared), matching every existing aggregator.
- **SwiftData-safe decoding**: every options struct persisted in `Feed.options` MUST have a custom `init(from:)` decoding each field with `decodeIfPresent` — SwiftData's composite decoder **traps (EXC_BREAKPOINT), not throws**, on a missing key. No exceptions, even for AI-only structs.
- **Exhaustive switches**: adding an enum case forces updates to every non-`default` switch. Files with such switches: `AggregatorType.swift` (displayName, brandSiteURL, defaultOptions), `AggregatorOptions.swift` (`ai` accessor), `AggregatorRegistry.swift` (makeAggregator + makeNewsScraper), `AggregatorOptionsForm.swift` (body + aiBinding). Omitting one = compile error.
- **Translations**: none expected — brand `displayName`s and `identifierChoices` labels are plain non-localized strings (existing convention); UI labels reuse keys already in `Localizable.xcstrings`. If any genuinely new user-facing localizable string is introduced, add a `de` `"translated"` entry per CLAUDE.md.
- **New files auto-compile** via XcodeGen folder globbing (`sources: - path: Yana`, `- path: YanaTests`). Run `xcodegen generate` before building (Task 3). No `project.yml` edit.
- **Build/test command**: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`

---

### Task 1: The Verge aggregator (vertical slice)

**Files:**
- Modify: `Yana/Models/AggregatorOptions.swift` — add `TheVergeOptions`, enum case, `ai` accessor case, decode extension
- Create: `Yana/Aggregators/Concrete/TheVergeAggregator.swift`
- Modify: `Yana/Aggregators/AggregatorType.swift` — add `theVerge` case + displayName + brandSiteURL + identifierChoices + defaultOptions
- Modify: `Yana/Aggregators/AggregatorRegistry.swift` — route `.theVerge`
- Modify: `Yana/Views/Config/AggregatorOptionsForm.swift` — body case + aiBinding case
- Test: `YanaTests/TheVergeAggregatorTests.swift` (create), `YanaTests/AggregatorOptionsTests.swift`, `YanaTests/AggregatorTypeTests.swift`, `YanaTests/AggregatorTypeLogoTests.swift`, `YanaTests/AggregatorRegistryScrapersTests.swift`

**Interfaces:**
- Produces: `TheVergeOptions` (`struct { var ai = AIOptions() }`); `AggregatorOptions.theVerge(TheVergeOptions)`; `AggregatorType.theVerge` (rawValue `"the_verge"`); `TheVergeAggregator: FullWebsiteAggregator` with `static let identifierChoices: [(value: String, label: String)]` and `static let defaultFeed: String`.
- Consumes: `FullWebsiteAggregator`, `HTMLUtils`, `EmbedRewriter`, `ContentFormatter`, `FeedParser`, `HTTPClient`, `AggregatorError` (all existing).

- [ ] **Step 1: Write the failing aggregator test**

Create `YanaTests/TheVergeAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("TheVergeAggregator")
struct TheVergeAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry() -> FeedEntry {
        FeedEntry(title: "Verge story", link: "https://www.theverge.com/a-1", content: "<p>s</p>",
                  summary: "<p>s</p>", entryDescription: nil, published: .now, author: "",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubVerge: TheVergeAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .theVerge, identifier: "https://www.theverge.com/rss/index.xml",
                                          dailyLimit: 20, options: .theVerge(TheVergeOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func extractsOnlyFirstArticleBodyBlock() async throws {
        // The Verge embeds related/"stream" article bodies with the same class; keep only the first.
        let page = """
        <html><body>
        <div class="duet--article--article-body-component"><p>Main article body</p></div>
        <div class="duet--article--article-body-component"><p>Related stream article</p></div>
        </body></html>
        """
        let agg = StubVerge(entries: [entry()], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Main article body"))
        #expect(!a.content.contains("Related stream article"))
    }

    @Test func removesAdAndNewsletterNoise() async throws {
        let page = """
        <div class="duet--article--article-body-component"><p>Keep this</p>\
        <div class="duet--ad-slot">ADCONTENT</div>\
        <div class="newsletter-signup">NEWSLETTERCONTENT</div></div>
        """
        let agg = StubVerge(entries: [entry()], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Keep this"))
        #expect(!a.content.contains("ADCONTENT"))
        #expect(!a.content.contains("NEWSLETTERCONTENT"))
    }

    @Test func identifierChoicesHasMainFeed() {
        #expect(TheVergeAggregator.identifierChoices.count == 1)
        #expect(TheVergeAggregator.identifierChoices.first?.value == "https://www.theverge.com/rss/index.xml")
    }
}
```

- [ ] **Step 2: Run test — verify it fails to compile**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -i "cannot find\|TheVergeAggregator\|TheVergeOptions"`
Expected: compile failure — `TheVergeAggregator` / `TheVergeOptions` / `.theVerge` not found.

- [ ] **Step 3: Add `TheVergeOptions` + enum wiring in `AggregatorOptions.swift`**

After the `FeedContentOptions` struct (the other AI-only struct), add:

```swift
struct TheVergeOptions: Codable, Sendable, Equatable {
    var ai = AIOptions()
}
```

In the `enum AggregatorOptions` case list, after `case feedContent(FeedContentOptions)` add:

```swift
    case theVerge(TheVergeOptions)
```

In the `ai` computed-property switch, after `case .feedContent(let o): o.ai` add:

```swift
        case .theVerge(let o): o.ai
```

At the end of the file, after the `extension FeedContentOptions` decode block, add:

```swift
extension TheVergeOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}
```

- [ ] **Step 4: Create `TheVergeAggregator.swift`**

Create `Yana/Aggregators/Concrete/TheVergeAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// The Verge (theverge.com) US tech/culture news. WordPress-backed with the Vox "Duet" design
/// system; the article body is `.duet--article--article-body-component`. The page also embeds
/// related/"stream" article bodies sharing that class, so we keep only the first (main-article)
/// block — the base `FullWebsiteAggregator` extraction already takes `.first()`.
class TheVergeAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://www.theverge.com/rss/index.xml"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://www.theverge.com/rss/index.xml", "Main Feed"),
    ]

    override var contentSelector: String { ".duet--article--article-body-component" }

    override var selectorsToRemove: [String] {
        ["script", "style", "noscript",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])",
         "aside",
         "[class*='duet--recirculation']",
         "[class*='duet--ad']",
         "[class*='newsletter']"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div", "span"])
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

- [ ] **Step 5: Add the `theVerge` case + metadata in `AggregatorType.swift`**

In the `enum AggregatorType` case list, after `case caschysBlog = "caschys_blog"` add:

```swift
    case theVerge = "the_verge"
```

In `displayName`, after the `.caschysBlog` line add:

```swift
        case .theVerge: "The Verge"
```

In `brandSiteURL`, after the `.caschysBlog` line add:

```swift
        case .theVerge: "https://www.theverge.com/"
```

Leave the `nil` group line (`case .fullWebsite, .feedContent, .youtube, .reddit, .podcast: nil`) unchanged — The Verge gets its own non-nil brandSiteURL above, and the switch stays exhaustive. No change to `identifierKind` (falls through to the `.url` default) or `requiredAPIKey` (`.none` default).

In `identifierChoices`, after the `.caschysBlog` line add:

```swift
        case .theVerge: TheVergeAggregator.identifierChoices
```

In `defaultOptions`, after the `.caschysBlog` line add:

```swift
        case .theVerge: .theVerge(TheVergeOptions())
```

- [ ] **Step 6: Route `.theVerge` in `AggregatorRegistry.swift`**

In `makeAggregator(_:credentials:)`, add `.theVerge` to the news-scraper group:

```swift
        case .heise, .merkur, .tagesschau, .caschysBlog, .mactechnews, .meinMmo, .theVerge:
            return makeNewsScraper(config.type, config: config, credentials: credentials)
```

In `makeNewsScraper(...)`, before `default: return nil` add:

```swift
        case .theVerge: return TheVergeAggregator(config: config, credentials: credentials)
```

- [ ] **Step 7: Wire the options-form UI in `AggregatorOptionsForm.swift`**

In the `body` switch, after the `.caschysBlog` case block add (AI-only → no per-type section):

```swift
            case .theVerge:
                EmptyView()
```

In the `aiBinding` set-switch, after the `.caschysBlog` line add:

```swift
                case .theVerge(var o): o.ai = newAI; options = .theVerge(o)
```

- [ ] **Step 8: Update the cross-cutting type/registry/options tests**

In `YanaTests/AggregatorTypeTests.swift`, change the count test to 15 and add displayName coverage:

```swift
    @Test func hasFifteenCases() {
        #expect(AggregatorType.allCases.count == 15)
    }
```
(Rename the old `hasAllFourteenCases` to `hasFifteenCases` and update the value.) In `displayNameIsHumanReadable`, add:

```swift
        #expect(AggregatorType.theVerge.displayName == "The Verge")
        #expect(AggregatorType.theVerge.rawValue == "the_verge")
```

In `YanaTests/AggregatorTypeLogoTests.swift`, inside `fixedBrandTypesHaveSiteURLs`, add:

```swift
        #expect(AggregatorType.theVerge.brandSiteURL == "https://www.theverge.com/")
```

In `YanaTests/AggregatorRegistryScrapersTests.swift`, inside `buildsEachScraperType`, add:

```swift
        #expect(r.makeAggregator(cfg(.theVerge, .theVerge(TheVergeOptions())), credentials: .init()) is TheVergeAggregator)
```

In `YanaTests/AggregatorOptionsTests.swift`, inside `optionsStructsDecodeFromEmptyObject`, add:

```swift
        _ = try JSONDecoder().decode(TheVergeOptions.self, from: empty)
```

- [ ] **Step 9: Run the tests — verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -30`
Expected: build succeeds; `TheVergeAggregator` suite passes (3 tests); no regressions in AggregatorType/Registry/Options suites.

- [ ] **Step 10: Commit**

```bash
git add Yana/Models/AggregatorOptions.swift Yana/Aggregators/Concrete/TheVergeAggregator.swift \
        Yana/Aggregators/AggregatorType.swift Yana/Aggregators/AggregatorRegistry.swift \
        Yana/Views/Config/AggregatorOptionsForm.swift YanaTests/TheVergeAggregatorTests.swift \
        YanaTests/AggregatorTypeTests.swift YanaTests/AggregatorTypeLogoTests.swift \
        YanaTests/AggregatorRegistryScrapersTests.swift YanaTests/AggregatorOptionsTests.swift
git commit -m "feat: add The Verge managed aggregator"
```

---

### Task 2: Ars Technica aggregator (vertical slice, in-page block merge)

**Files:**
- Modify: `Yana/Models/AggregatorOptions.swift` — add `ArsTechnicaOptions`, enum case, `ai` accessor case, decode extension
- Create: `Yana/Aggregators/Concrete/ArsTechnicaAggregator.swift`
- Modify: `Yana/Aggregators/AggregatorType.swift` — add `arsTechnica` case + metadata
- Modify: `Yana/Aggregators/AggregatorRegistry.swift` — route `.arsTechnica`
- Modify: `Yana/Views/Config/AggregatorOptionsForm.swift` — body case + aiBinding case
- Test: `YanaTests/ArsTechnicaAggregatorTests.swift` (create), and the same 4 cross-cutting test files as Task 1

**Interfaces:**
- Consumes: `TheVergeAggregator` pattern from Task 1; `FullWebsiteAggregator.enrich` shape; `HeaderElementExtractor.extract`, `HTMLUtils.extractMainContent`, `processContent` (existing base methods).
- Produces: `ArsTechnicaOptions` (`struct { var ai = AIOptions() }`); `AggregatorOptions.arsTechnica`; `AggregatorType.arsTechnica` (rawValue `"ars_technica"`); `ArsTechnicaAggregator: FullWebsiteAggregator` with `static let identifierChoices` (4 entries), `static let defaultFeed`, and `func mergedContentHTML(from:) -> String?`.

- [ ] **Step 1: Write the failing aggregator test**

Create `YanaTests/ArsTechnicaAggregatorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("ArsTechnicaAggregator")
struct ArsTechnicaAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry() -> FeedEntry {
        FeedEntry(title: "Ars story", link: "https://arstechnica.com/a/2026/07/x/", content: "<p>s</p>",
                  summary: "<p>s</p>", entryDescription: nil, published: .now, author: "",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubArs: ArsTechnicaAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .arsTechnica, identifier: "https://arstechnica.com/feed/",
                                          dailyLimit: 20, options: .arsTechnica(ArsTechnicaOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func mergesAllPostContentBlocksFromOnePage() async throws {
        // Multi-"page" Ars articles serve every page in one fetch as sibling .post-content blocks.
        let page = """
        <html><body>
        <div class="post-content post-content-double"><p>Page one prose</p></div>
        <a data-page="2" class="record-pageview"></a>
        <div class="post-content post-content-double"><p>Page two prose</p></div>
        </body></html>
        """
        let agg = StubArs(entries: [entry()], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Page one prose"))
        #expect(a.content.contains("Page two prose"))   // not truncated to the first block
    }

    @Test func removesAdWrappers() async throws {
        let page = """
        <div class="post-content post-content-double"><p>Keep this</p>\
        <div class="ad-wrapper is-rail">ADCONTENT</div></div>
        """
        let agg = StubArs(entries: [entry()], page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Keep this"))
        #expect(!a.content.contains("ADCONTENT"))
    }

    @Test func identifierChoicesHasFourSections() {
        #expect(ArsTechnicaAggregator.identifierChoices.count == 4)
        #expect(ArsTechnicaAggregator.identifierChoices.map(\.value) == [
            "https://arstechnica.com/feed/",
            "https://arstechnica.com/gadgets/feed/",
            "https://arstechnica.com/science/feed/",
            "https://arstechnica.com/gaming/feed/",
        ])
    }
}
```

- [ ] **Step 2: Run test — verify it fails to compile**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -i "cannot find\|ArsTechnica"`
Expected: compile failure — `ArsTechnicaAggregator` / `ArsTechnicaOptions` / `.arsTechnica` not found.

- [ ] **Step 3: Add `ArsTechnicaOptions` + enum wiring in `AggregatorOptions.swift`**

After the `TheVergeOptions` struct add:

```swift
struct ArsTechnicaOptions: Codable, Sendable, Equatable {
    var ai = AIOptions()
}
```

In the enum, after `case theVerge(TheVergeOptions)` add:

```swift
    case arsTechnica(ArsTechnicaOptions)
```

In the `ai` switch, after `case .theVerge(let o): o.ai` add:

```swift
        case .arsTechnica(let o): o.ai
```

At the end of the file, after `extension TheVergeOptions`, add:

```swift
extension ArsTechnicaOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}
```

- [ ] **Step 4: Create `ArsTechnicaAggregator.swift`**

Create `Yana/Aggregators/Concrete/ArsTechnicaAggregator.swift`:

```swift
import Foundation
import SwiftSoup

/// Ars Technica (arstechnica.com) US tech/science news. Multi-"page" articles are served whole in a
/// single fetch as sibling `div.post-content` blocks separated by `<a data-page="N">` trackers (the
/// `/N/` URLs are same-page `#page-N` anchors). Even single-page articles split into multiple
/// `.post-content` blocks, so we merge ALL of them — the base extraction keeps only `.first()`,
/// which would truncate the article.
class ArsTechnicaAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://arstechnica.com/feed/"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://arstechnica.com/feed/", "Main Feed"),
        ("https://arstechnica.com/gadgets/feed/", "Gadgets"),
        ("https://arstechnica.com/science/feed/", "Science"),
        ("https://arstechnica.com/gaming/feed/", "Gaming"),
    ]

    override var contentSelector: String { ".post-content" }

    override var selectorsToRemove: [String] {
        [".ad", "[class*='ad-wrapper']", ".ad--mid-content", ".ad--rail",
         ".social-share", "aside", "script", "style", "noscript",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    /// Merge every `.post-content` block in the fetched page into one wrapped HTML string
    /// (document order). Returns nil when none are present so the caller falls back to RSS content.
    func mergedContentHTML(from pageHTML: String) -> String? {
        guard let doc = try? HTMLUtils.parse(pageHTML) else { return nil }
        let blocks = (try? doc.select(".post-content").array()) ?? []
        let inner = blocks.compactMap { try? $0.html() }.filter { !$0.isEmpty }
        guard !inner.isEmpty else { return nil }
        return "<div class=\"post-content\">\(inner.joined(separator: "\n\n"))</div>"
    }

    /// Like the base enrich, but sources content from the merged in-page blocks instead of the
    /// single `.first()` match. Keeps the base's RSS/cancellation fallback shape.
    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        do {
            let raw = try await fetchArticleHTML(article.url)
            article.rawContent = raw
            let header = await HeaderElementExtractor.extract(
                articleURL: article.url, title: article.title, store: store,
                credentials: credentials, pageHTML: raw)
            guard let merged = mergedContentHTML(from: raw) else {
                article.content = try await processContent(article.content, article: article, headerHTML: nil)
                return article
            }
            let extracted = try HTMLUtils.extractMainContent(merged, selector: ".post-content",
                                                             removeSelectors: selectorsToRemove)
            article.content = try await processFullContent(extracted, article: article, header: header)
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }
            if Task.isCancelled { throw CancellationError() }
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        } catch {
            if error.isCancellationError || Task.isCancelled { throw CancellationError() }
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        }
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div", "span"])
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

- [ ] **Step 5: Add the `arsTechnica` case + metadata in `AggregatorType.swift`**

In the enum case list, after `case theVerge = "the_verge"` add:

```swift
    case arsTechnica = "ars_technica"
```

In `displayName`, after `.theVerge`:

```swift
        case .arsTechnica: "Ars Technica"
```

In `brandSiteURL`, after `.theVerge`:

```swift
        case .arsTechnica: "https://arstechnica.com/"
```

In `identifierChoices`, after `.theVerge`:

```swift
        case .arsTechnica: ArsTechnicaAggregator.identifierChoices
```

In `defaultOptions`, after `.theVerge`:

```swift
        case .arsTechnica: .arsTechnica(ArsTechnicaOptions())
```

- [ ] **Step 6: Route `.arsTechnica` in `AggregatorRegistry.swift`**

Add `.arsTechnica` to the news-scraper group in `makeAggregator`:

```swift
        case .heise, .merkur, .tagesschau, .caschysBlog, .mactechnews, .meinMmo, .theVerge, .arsTechnica:
            return makeNewsScraper(config.type, config: config, credentials: credentials)
```

In `makeNewsScraper`, before `default: return nil`:

```swift
        case .arsTechnica: return ArsTechnicaAggregator(config: config, credentials: credentials)
```

- [ ] **Step 7: Wire the options-form UI in `AggregatorOptionsForm.swift`**

In `body`, after the `.theVerge` case:

```swift
            case .arsTechnica:
                EmptyView()
```

In `aiBinding`, after the `.theVerge` line:

```swift
                case .arsTechnica(var o): o.ai = newAI; options = .arsTechnica(o)
```

- [ ] **Step 8: Update the cross-cutting tests**

In `YanaTests/AggregatorTypeTests.swift`, bump the count test to 16 and add coverage:

```swift
    @Test func hasSixteenCases() {
        #expect(AggregatorType.allCases.count == 16)
    }
```
(Rename `hasFifteenCases` → `hasSixteenCases`, value 15 → 16.) In `displayNameIsHumanReadable`, add:

```swift
        #expect(AggregatorType.arsTechnica.displayName == "Ars Technica")
        #expect(AggregatorType.arsTechnica.rawValue == "ars_technica")
```

In `YanaTests/AggregatorTypeLogoTests.swift` → `fixedBrandTypesHaveSiteURLs`, add:

```swift
        #expect(AggregatorType.arsTechnica.brandSiteURL == "https://arstechnica.com/")
```

In `YanaTests/AggregatorRegistryScrapersTests.swift` → `buildsEachScraperType`, add:

```swift
        #expect(r.makeAggregator(cfg(.arsTechnica, .arsTechnica(ArsTechnicaOptions())), credentials: .init()) is ArsTechnicaAggregator)
```

In `YanaTests/AggregatorOptionsTests.swift` → `optionsStructsDecodeFromEmptyObject`, add:

```swift
        _ = try JSONDecoder().decode(ArsTechnicaOptions.self, from: empty)
```

- [ ] **Step 9: Run the tests — verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -30`
Expected: build succeeds; `ArsTechnicaAggregator` suite passes (3 tests); AggregatorType count test passes at 16; no regressions.

- [ ] **Step 10: Commit**

```bash
git add Yana/Models/AggregatorOptions.swift Yana/Aggregators/Concrete/ArsTechnicaAggregator.swift \
        Yana/Aggregators/AggregatorType.swift Yana/Aggregators/AggregatorRegistry.swift \
        Yana/Views/Config/AggregatorOptionsForm.swift YanaTests/ArsTechnicaAggregatorTests.swift \
        YanaTests/AggregatorTypeTests.swift YanaTests/AggregatorTypeLogoTests.swift \
        YanaTests/AggregatorRegistryScrapersTests.swift YanaTests/AggregatorOptionsTests.swift
git commit -m "feat: add Ars Technica managed aggregator with in-page block merge"
```

---

### Task 3: Regenerate project, full verification, docs

**Files:**
- Modify: `CLAUDE.md` — extend the aggregator-types list
- Modify: `Yana/Aggregators/AggregatorType.swift` — (optional) enum-level docstring only if it enumerates types

**Interfaces:**
- Consumes: everything from Tasks 1–2.
- Produces: a regenerated `Yana.xcodeproj` including the two new source files and two new test files; updated docs.

- [ ] **Step 1: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: `Created project at Yana.xcodeproj`. (New files under `Yana/` and `YanaTests/` are folder-globbed in.)

- [ ] **Step 2: Confirm the new files are in the project**

Run: `grep -c "TheVergeAggregator\|ArsTechnicaAggregator" Yana.xcodeproj/project.pbxproj`
Expected: a non-zero count (both source files referenced).

- [ ] **Step 3: Full clean build + test run**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -40`
Expected: `TEST SUCCEEDED`. Both new suites present; existing suites green (note: Swift Testing reports its total separately from the single XCTest UI test — see the project's known test-count reporting).

- [ ] **Step 4: Update the aggregator list in `CLAUDE.md`**

In the `### Aggregator types` section, extend the sentence listing managed scrapers to include the two new ones. Change:

```
the managed scrapers (`heise`, `merkur`, `tagesschau`, `explosm`, `darkLegacy`,
`caschysBlog`, `mactechnews`, `oglaf`, `meinMmo`), and the social/media sources
```

to:

```
the managed scrapers (`heise`, `merkur`, `tagesschau`, `explosm`, `darkLegacy`,
`caschysBlog`, `mactechnews`, `oglaf`, `meinMmo`, `theVerge`, `arsTechnica`), and the social/media sources
```

Also update the `AggregatorType` covers list a few lines up if it enumerates the same set (keep the two lists consistent).

- [ ] **Step 5: Verify no untranslated strings were introduced**

Run: `git diff --stat Yana/Resources/Localizable.xcstrings`
Expected: no changes (brand names and choice labels are plain non-localized strings; UI reused existing keys). If the diff is non-empty, ensure every new string has a `de` `"translated"` entry per CLAUDE.md before committing.

- [ ] **Step 6: Commit**

```bash
git add Yana.xcodeproj/project.pbxproj CLAUDE.md
git commit -m "chore: regenerate project and document Verge/Ars aggregators"
```

---

## Self-Review Notes

- **Spec coverage:** The Verge type (Task 1), Ars type + in-page merge (Task 2), options structs + SwiftData-safe decode (Tasks 1–2), type metadata/registry/UI wiring (Tasks 1–2), tests incl. merge-not-truncated and choices (Tasks 1–2), project regen + docs (Task 3). All spec sections mapped.
- **Selector caveat:** `selectorsToRemove` lists and the exact The-Verge noise classes are starting sets derived from live pages captured 2026-07-07; if a test against a fuller captured fixture shows leftover chrome, refine the selector list in the relevant aggregator file (no interface change).
- **Type consistency:** `identifierChoices` typed `[(value: String, label: String)]` throughout; `mergedContentHTML(from:) -> String?`; enum raw values `"the_verge"` / `"ars_technica"`; count assertions 15 (after Task 1) → 16 (after Task 2).
