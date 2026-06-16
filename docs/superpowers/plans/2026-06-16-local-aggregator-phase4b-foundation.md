# Phase 4b — Aggregation Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared, network-and-HTML foundation every aggregator depends on — HTTP fetch, RSS/Atom parsing, SwiftSoup HTML utilities, the article-content wrapper, proxy-identical embed rewriting, the on-device image cache + custom WebView scheme, and the header-element extractor.

**Architecture:** A `Yana/Aggregators/Utils/` module of small focused units mirroring the server's `core/aggregators/utils/` + `services/header_element/`. Networking is `async` and runs off the main actor; HTML is parsed with **SwiftSoup** (the BeautifulSoup analogue); images are downloaded, compressed with ImageIO, stored as files keyed by content hash, and referenced from article HTML via a custom `yana-img://` scheme served by a `WKURLSchemeHandler`. No remote image URLs ever reach the WebView. Tests are hermetic — fixtures are inline string literals and network is injected.

**Tech Stack:** Swift 6, SwiftData, SwiftSoup (SPM), ImageIO/CoreGraphics, WebKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-16-local-aggregator-phase4-design.md` (§3, decision 3 + 4).

**Depends on:** Phase 4a (FeedConfig, Aggregator protocol, AggregatorError).

---

## Interface contract (referenced by 4c–4g)

These signatures are the public surface later plans build on. Keep them stable.

```swift
// HTTP
enum HTTPClient {
    static let userAgent = "Mozilla/5.0 (compatible; YanaBot/1.0; +https://github.com/fa-krug/Yana)"
    static func fetchHTML(_ url: URL, timeout: TimeInterval = 30) async throws -> String
    static func fetchData(_ url: URL, timeout: TimeInterval = 30) async throws -> (data: Data, contentType: String?)
    static func fetchJSON(_ request: URLRequest) async throws -> Data   // for API aggregators (4e/4f)
}

// Feed parsing
struct FeedEnclosure: Sendable { var url: String; var type: String? }
struct FeedEntry: Sendable {
    var title: String; var link: String
    var content: String?; var summary: String?; var entryDescription: String?
    var published: Date?; var author: String
    var enclosures: [FeedEnclosure]
    var itunesDuration: String?; var itunesImage: String?; var mediaThumbnails: [String]
}
struct ParsedFeed: Sendable { var entries: [FeedEntry] }
enum FeedParser { static func parse(_ data: Data) throws -> ParsedFeed; static func parseDate(_ s: String?) -> Date? }

// HTML utilities (SwiftSoup)
enum HTMLUtils {
    static func parse(_ html: String) throws -> Document
    static func removeComments(_ doc: Document) throws
    static func sanitizeClassNames(_ doc: Document) throws
    static func removeEmptyElements(_ doc: Document, tags: [String]) throws
    static func removeImageByURL(_ doc: Document, url: String) throws
    static func extractMainContent(_ html: String, selector: String, removeSelectors: [String]) throws -> String
    static func bodyHTML(_ doc: Document) throws -> String
}

// Content wrapper + embeds
enum ContentFormatter {
    static func format(content: String, title: String, url: String, headerHTML: String?, commentsHTML: String?) -> String
}
enum EmbedRewriter {
    static func extractYouTubeID(from url: String) -> String?
    static func youTubeEmbedHTML(videoID: String) -> String
    static func dailymotionEmbedHTML(videoID: String) -> String
    static func rewriteEmbeds(in doc: Document) throws
    static func tweetEmbedHTML(for url: String) async -> String?
}

// Reader/web constants
enum ReaderWeb {
    static let baseOrigin = "https://app.yana.local"
    static let imageScheme = "yana-img"
}

// Image pipeline
enum ImageCompressor {
    static func compress(_ data: Data, contentType: String?, isHeader: Bool) -> (data: Data, ext: String)?
}
actor ImageStore {
    init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> (Data, String?))
    func store(remoteURL: URL, isHeader: Bool) async -> String?     // returns content hash, or nil
    func fileURL(forHash hash: String) -> URL
    func purgeOrphans(keepingHashes: Set<String>)
    static let shared: ImageStore
}
func rewriteImages(in doc: Document, store: ImageStore, baseURL: URL?) async throws
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler { init(store: ImageStore) }

// Header element
struct HeaderElement: Sendable { var html: String; var dedupURL: String? }
enum HeaderElementExtractor {
    static func extract(articleURL: String, title: String, store: ImageStore, credentials: AggregatorCredentials) async -> HeaderElement?
}
```

Build/test command:

```
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

---

## Task 1: Add the SwiftSoup dependency

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add the package + target dependency**

In `project.yml`, add a top-level `packages:` block (after the `options:`/`settings:` blocks, before `targets:`):

```yaml
packages:
  SwiftSoup:
    url: https://github.com/scinfu/SwiftSoup.git
    from: "2.7.5"
```

Then under `targets: → Yana:`, add a `dependencies:` key (sibling of `sources:`/`settings:`):

```yaml
    dependencies:
      - package: SwiftSoup
```

- [ ] **Step 2: Regenerate the project**

Run: `xcodegen generate`
Expected: "Created project at .../Yana.xcodeproj".

- [ ] **Step 3: Verify it builds with the dependency resolved**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (SwiftSoup resolves and links).

- [ ] **Step 4: Commit**

```bash
git add project.yml Yana.xcodeproj
git commit -m "build: add SwiftSoup dependency"
```

---

## Task 2: `HTTPClient` + `AggregatorError` cases

**Files:**
- Create: `Yana/Aggregators/Utils/HTTPClient.swift`
- Modify: `Yana/Aggregators/Aggregator.swift`
- Test: `YanaTests/HTTPClientTests.swift`

- [ ] **Step 1: Add error cases**

In `Yana/Aggregators/Aggregator.swift`, extend `AggregatorError` with new cases and descriptions:

```swift
enum AggregatorError: Error, LocalizedError {
    case missingIdentifier
    case missingAPIKey(AggregatorAPIKey)
    case notImplemented(AggregatorType)
    case articleSkip(statusCode: Int)
    case contentFetch(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .missingIdentifier:
            String(localized: "This feed needs an identifier (URL, subreddit, or channel).")
        case .missingAPIKey:
            String(localized: "This aggregator requires an API key. Add it in Settings.")
        case .notImplemented(let type):
            String(localized: "The \(type.displayName) aggregator is not available yet.")
        case .articleSkip(let code):
            String(localized: "Article skipped (HTTP \(code)).")
        case .contentFetch(let message):
            String(localized: "Could not fetch content: \(message)")
        case .parse(let message):
            String(localized: "Could not parse content: \(message)")
        }
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `YanaTests/HTTPClientTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("HTTPClient")
struct HTTPClientTests {
    @Test func userAgentIsBotIdentified() {
        #expect(HTTPClient.userAgent.contains("YanaBot"))
    }

    @Test func skipErrorCarriesStatusCode() {
        let error = AggregatorError.articleSkip(statusCode: 404)
        #expect(error.errorDescription?.contains("404") == true)
    }
}
```

(Live network is never tested; `fetchHTML`/`fetchData` are exercised indirectly via injected fakes in later tasks.)

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HTTPClientTests`
Expected: FAIL — `cannot find 'HTTPClient' in scope`.

- [ ] **Step 4: Implement `HTTPClient`**

Create `Yana/Aggregators/Utils/HTTPClient.swift`:

```swift
import Foundation

/// Async HTTP wrapper: browser-ish UA, timeout, retry with exponential backoff,
/// and `AggregatorError.articleSkip` on 4xx (mirrors the server's html_fetcher + ArticleSkipError).
enum HTTPClient {
    static let userAgent = "Mozilla/5.0 (compatible; YanaBot/1.0; +https://github.com/fa-krug/Yana)"

    static func fetchHTML(_ url: URL, timeout: TimeInterval = 30) async throws -> String {
        let (data, _) = try await fetchData(url, timeout: timeout)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw AggregatorError.parse("response was not decodable text")
        }
        return html
    }

    static func fetchData(_ url: URL, timeout: TimeInterval = 30) async throws -> (data: Data, contentType: String?) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    static func fetchJSON(_ request: URLRequest) async throws -> Data {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return try await send(request).data
    }

    private static func send(_ request: URLRequest, maxAttempts: Int = 3) async throws -> (data: Data, contentType: String?) {
        var lastError: Error = AggregatorError.contentFetch("unknown")
        for attempt in 0..<maxAttempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if (400..<500).contains(http.statusCode) {
                        throw AggregatorError.articleSkip(statusCode: http.statusCode)
                    }
                    if http.statusCode >= 500 {
                        throw AggregatorError.contentFetch("HTTP \(http.statusCode)")
                    }
                    let contentType = http.value(forHTTPHeaderField: "Content-Type")
                    return (data, contentType)
                }
                return (data, nil)
            } catch let error as AggregatorError {
                if case .articleSkip = error { throw error }   // 4xx: do not retry
                lastError = error
            } catch {
                lastError = error
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
            }
        }
        throw lastError
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HTTPClientTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Utils/HTTPClient.swift Yana/Aggregators/Aggregator.swift YanaTests/HTTPClientTests.swift
git commit -m "feat: HTTPClient with retry + 4xx skip; extend AggregatorError"
```

---

## Task 3: `FeedParser` — RSS/Atom/RDF → `ParsedFeed`

**Files:**
- Create: `Yana/Aggregators/Utils/FeedParser.swift`
- Test: `YanaTests/FeedParserTests.swift`

- [ ] **Step 1: Write the failing test (inline RSS + Atom fixtures)**

Create `YanaTests/FeedParserTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("FeedParser")
struct FeedParserTests {
    private let rss = """
    <?xml version="1.0"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <item>
          <title>First</title>
          <link>https://ex.com/1</link>
          <author>Alice</author>
          <pubDate>Wed, 02 Oct 2002 13:00:00 GMT</pubDate>
          <description>Desc one</description>
          <content:encoded xmlns:content="http://purl.org/rss/1.0/modules/content/"><![CDATA[<p>Full one</p>]]></content:encoded>
          <enclosure url="https://ex.com/1.mp3" type="audio/mpeg"/>
          <itunes:duration>1:01:01</itunes:duration>
        </item>
      </channel>
    </rss>
    """

    private let atom = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <title>Atom Title</title>
        <link href="https://ex.com/a1"/>
        <author><name>Bob</name></author>
        <updated>2003-12-13T18:30:02Z</updated>
        <content type="html">&lt;p&gt;Atom body&lt;/p&gt;</content>
      </entry>
    </feed>
    """

    @Test func parsesRssItemFields() throws {
        let feed = try FeedParser.parse(Data(rss.utf8))
        let entry = try #require(feed.entries.first)
        #expect(entry.title == "First")
        #expect(entry.link == "https://ex.com/1")
        #expect(entry.author == "Alice")
        #expect(entry.content?.contains("Full one") == true)
        #expect(entry.entryDescription?.contains("Desc one") == true)
        #expect(entry.enclosures.first?.url == "https://ex.com/1.mp3")
        #expect(entry.enclosures.first?.type == "audio/mpeg")
        #expect(entry.itunesDuration == "1:01:01")
        #expect(entry.published != nil)
    }

    @Test func parsesAtomEntryFields() throws {
        let feed = try FeedParser.parse(Data(atom.utf8))
        let entry = try #require(feed.entries.first)
        #expect(entry.title == "Atom Title")
        #expect(entry.link == "https://ex.com/a1")
        #expect(entry.author == "Bob")
        #expect(entry.content?.contains("Atom body") == true)
        #expect(entry.published != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedParserTests`
Expected: FAIL — `cannot find 'FeedParser' in scope`.

- [ ] **Step 3: Implement `FeedParser` with `XMLParser`**

Create `Yana/Aggregators/Utils/FeedParser.swift`:

```swift
import Foundation

struct FeedEnclosure: Sendable { var url: String; var type: String? }

struct FeedEntry: Sendable {
    var title = ""
    var link = ""
    var content: String?
    var summary: String?
    var entryDescription: String?
    var published: Date?
    var author = ""
    var enclosures: [FeedEnclosure] = []
    var itunesDuration: String?
    var itunesImage: String?
    var mediaThumbnails: [String] = []
}

struct ParsedFeed: Sendable { var entries: [FeedEntry] }

/// Minimal RSS 2.0 / RDF / Atom parser (replaces feedparser). Tolerant of namespaces.
enum FeedParser {
    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = FeedXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false   // keep prefixed names like content:encoded, itunes:duration
        guard parser.parse() else {
            throw AggregatorError.parse(parser.parserError?.localizedDescription ?? "invalid feed XML")
        }
        return ParsedFeed(entries: delegate.entries)
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        // RFC 822 (RSS pubDate)
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"] {
            rfc822.dateFormat = fmt
            if let d = rfc822.date(from: s) { return d }
        }
        // ISO 8601 (Atom updated/published)
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [FeedEntry] = []
    private var current: FeedEntry?
    private var text = ""
    private var inItem = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qn: String?, attributes attrs: [String: String]) {
        text = ""
        let lower = name.lowercased()
        if lower == "item" || lower == "entry" {
            inItem = true
            current = FeedEntry()
        } else if inItem, lower == "link", let href = attrs["href"], !href.isEmpty {
            current?.link = href                      // Atom <link href=...>
        } else if inItem, lower == "enclosure", let url = attrs["url"] {
            current?.enclosures.append(FeedEnclosure(url: url, type: attrs["type"]))
        } else if inItem, lower.hasSuffix("itunes:image") || lower == "itunes:image", let href = attrs["href"] {
            current?.itunesImage = href
        } else if inItem, lower == "media:thumbnail", let url = attrs["url"] {
            current?.mediaThumbnails.append(url)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qn: String?) {
        let lower = name.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard inItem, current != nil else { return }
        switch lower {
        case "item", "entry":
            if let c = current { entries.append(c) }
            current = nil; inItem = false
        case "title": current?.title = trimmed
        case "link" where !trimmed.isEmpty: if current?.link.isEmpty ?? true { current?.link = trimmed }
        case "author", "dc:creator", "name": if current?.author.isEmpty ?? true { current?.author = trimmed }
        case "description": current?.entryDescription = trimmed
        case "summary": current?.summary = trimmed
        case "content:encoded", "content": current?.content = trimmed
        case "pubdate", "published", "updated", "dc:date": if current?.published == nil { current?.published = FeedParser.parseDate(trimmed) }
        case "itunes:duration": current?.itunesDuration = trimmed
        default: break
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedParserTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/FeedParser.swift YanaTests/FeedParserTests.swift
git commit -m "feat: RSS/Atom/RDF feed parser"
```

---

## Task 4: `HTMLUtils` — SwiftSoup parsing/cleaning/extraction

**Files:**
- Create: `Yana/Aggregators/Utils/HTMLUtils.swift`
- Test: `YanaTests/HTMLUtilsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/HTMLUtilsTests.swift`:

```swift
import Foundation
import Testing
import SwiftSoup
@testable import Yana

@Suite("HTMLUtils")
struct HTMLUtilsTests {
    @Test func sanitizeClassNamesRewritesClassAttr() throws {
        let doc = try HTMLUtils.parse("<div class=\"foo bar\">x</div>")
        try HTMLUtils.sanitizeClassNames(doc)
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(html.contains("data-sanitized-class=\"foo bar\""))
        #expect(!html.contains("<div class="))   // the bare class attribute is gone
    }

    @Test func extractMainContentPicksSelectorAndRemoves() throws {
        let html = "<html><body><article><p>Keep</p><div class=\"ad\">Ad</div></article><footer>f</footer></body></html>"
        let out = try HTMLUtils.extractMainContent(html, selector: "article", removeSelectors: [".ad"])
        #expect(out.contains("Keep"))
        #expect(!out.contains("Ad"))
        #expect(!out.contains("<footer"))
    }

    @Test func removeEmptyElementsDropsBlankParagraphs() throws {
        let doc = try HTMLUtils.parse("<p>real</p><p></p><p>   </p>")
        try HTMLUtils.removeEmptyElements(doc, tags: ["p"])
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(html.contains("real"))
        // Only the non-empty paragraph should remain.
        let openParagraphCount = html.components(separatedBy: "<p").count - 1
        #expect(openParagraphCount == 1)
    }

    @Test func removeImageByURLMatchesResponsiveVariant() throws {
        // Basename "photo" (5 chars) > 3 so it matches the server-faithful length guard;
        // the responsive variant suffix -780x438 is stripped before comparison.
        let doc = try HTMLUtils.parse("<img src=\"https://x.com/photo-780x438.jpg\"><p>body</p>")
        try HTMLUtils.removeImageByURL(doc, url: "https://x.com/photo.jpg")
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(!html.contains("<img"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HTMLUtilsTests`
Expected: FAIL — `cannot find 'HTMLUtils' in scope`.

- [ ] **Step 3: Implement `HTMLUtils`**

Create `Yana/Aggregators/Utils/HTMLUtils.swift`:

```swift
import Foundation
import SwiftSoup

/// SwiftSoup-backed HTML utilities mirroring the server's html_cleaner / content_extractor.
enum HTMLUtils {
    static func parse(_ html: String) throws -> Document { try SwiftSoup.parse(html) }

    static func bodyHTML(_ doc: Document) throws -> String { try doc.body()?.html() ?? doc.html() }

    static func removeComments(_ doc: Document) throws {
        // SwiftSoup exposes comments as Comment nodes; walk and remove.
        let nodes = try doc.getAllElements()
        for el in nodes {
            for child in el.getChildNodes() where child is Comment {
                try child.remove()
            }
        }
    }

    static func sanitizeClassNames(_ doc: Document) throws {
        for el in try doc.getAllElements() where el.hasAttr("class") {
            let value = try el.attr("class")
            try el.removeAttr("class")
            try el.attr("data-sanitized-class", value)
        }
    }

    static func removeEmptyElements(_ doc: Document, tags: [String]) throws {
        for tag in tags {
            for el in try doc.select(tag) {
                let text = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
                let hasMedia = !(try el.select("img, iframe, video").isEmpty())
                if text.isEmpty && !hasMedia { try el.remove() }
            }
        }
    }

    static func removeImageByURL(_ doc: Document, url: String) throws {
        guard !url.isEmpty, !url.hasPrefix("data:") else { return }
        let targetBase = baseFilename(url)
        let targetFile = (url as NSString).lastPathComponent
        for img in try doc.select("img") {
            let src = try firstNonEmpty(img, ["src", "data-src", "data-lazy-src"])
            guard let src, !src.hasPrefix("data:") else { continue }
            let file = (src as NSString).lastPathComponent
            if src == url || (file == targetFile && file.count > 3) || (baseFilename(src) == targetBase && targetBase.count > 3) {
                try img.remove()
                return
            }
        }
    }

    static func extractMainContent(_ html: String, selector: String, removeSelectors: [String]) throws -> String {
        let doc = try parse(html)
        let content: Element = (try? doc.select(selector).first()) ?? doc.body() ?? doc
        for sel in removeSelectors {
            for el in try content.select(sel) { try el.remove() }
        }
        return try content.html()
    }

    // MARK: - Filename helpers (mirror server _get_base_filename)

    private static func baseFilename(_ url: String) -> String {
        var name = (url as NSString).lastPathComponent
        if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
        name = name.replacingOccurrences(of: #"(?:-\d+x\d+|-\d+)+$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"-[a-zA-Z0-9]{3,6}$"#, with: "", options: .regularExpression)
        return name
    }

    private static func firstNonEmpty(_ el: Element, _ attrs: [String]) throws -> String? {
        for a in attrs {
            let v = try el.attr(a)
            if !v.isEmpty { return v }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HTMLUtilsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/HTMLUtils.swift YanaTests/HTMLUtilsTests.swift
git commit -m "feat: SwiftSoup HTML utilities (sanitize, extract, remove)"
```

---

## Task 5: `ContentFormatter` — article HTML wrapper

**Files:**
- Create: `Yana/Aggregators/Utils/ContentFormatter.swift`
- Test: `YanaTests/ContentFormatterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ContentFormatterTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("ContentFormatter")
struct ContentFormatterTests {
    @Test func wrapsContentWithSectionAndFooter() {
        let out = ContentFormatter.format(content: "<p>body</p>", title: "T", url: "https://x.com/1", headerHTML: nil, commentsHTML: nil)
        #expect(out.contains("<section data-sanitized-class=\"article-content\"><p>body</p></section>"))
        #expect(out.contains("Source: <a href=\"https://x.com/1\""))
    }

    @Test func includesHeaderAndComments() {
        let out = ContentFormatter.format(content: "<p>b</p>", title: "T", url: "u", headerHTML: "<header>H</header>", commentsHTML: "<p>c</p>")
        #expect(out.contains("<header>H</header>"))
        #expect(out.contains("data-sanitized-class=\"article-comments\""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ContentFormatterTests`
Expected: FAIL — `cannot find 'ContentFormatter' in scope`.

- [ ] **Step 3: Implement `ContentFormatter`**

Create `Yana/Aggregators/Utils/ContentFormatter.swift`:

```swift
import Foundation

/// Wraps article content in the server's exact shape: optional header, content section,
/// optional comments section, source footer (content_formatter.py parity).
enum ContentFormatter {
    static func format(content: String, title: String, url: String, headerHTML: String?, commentsHTML: String?) -> String {
        var parts: [String] = []
        if let headerHTML, !headerHTML.isEmpty { parts.append(headerHTML) }
        parts.append("<section data-sanitized-class=\"article-content\">\(content)</section>")
        if let commentsHTML, !commentsHTML.isEmpty {
            parts.append("<section data-sanitized-class=\"article-comments\">\(commentsHTML)</section>")
        }
        let escapedURL = url.replacingOccurrences(of: "\"", with: "&quot;")
        parts.append("<footer><p>Source: <a href=\"\(escapedURL)\" target=\"_blank\" rel=\"noopener\">\(escapedURL)</a></p></footer>")
        return parts.joined(separator: "\n\n")
    }

    /// Standard header markup for an already-cached header image (referenced via yana-img://).
    static func headerImageHTML(src: String, alt: String, captionHTML: String? = nil) -> String {
        let safeAlt = alt.replacingOccurrences(of: "\"", with: "&quot;")
        var html = "<header style=\"margin-bottom: 1.5em; text-align: center;\">"
        html += "<img src=\"\(src)\" alt=\"\(safeAlt)\" style=\"max-width: 100%; height: auto; border-radius: 8px;\">"
        if let captionHTML { html += captionHTML }
        html += "</header>"
        return html
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ContentFormatterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/ContentFormatter.swift YanaTests/ContentFormatterTests.swift
git commit -m "feat: article content wrapper (header/content/comments/footer)"
```

---

## Task 6: `EmbedRewriter` — proxy-identical embeds

**Files:**
- Create: `Yana/Aggregators/Utils/EmbedRewriter.swift`
- Test: `YanaTests/EmbedRewriterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/EmbedRewriterTests.swift`:

```swift
import Foundation
import Testing
import SwiftSoup
@testable import Yana

@Suite("EmbedRewriter")
struct EmbedRewriterTests {
    @Test func extractsVideoIDFromVariants() {
        #expect(EmbedRewriter.extractYouTubeID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(EmbedRewriter.extractYouTubeID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5") == "dQw4w9WgXcQ")
        #expect(EmbedRewriter.extractYouTubeID(from: "https://www.youtube.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test func youTubeEmbedMatchesProxyShape() {
        let html = EmbedRewriter.youTubeEmbedHTML(videoID: "abc12345678")
        #expect(html.contains("youtube-embed-container"))
        #expect(html.contains("https://www.youtube-nocookie.com/embed/abc12345678?"))
        #expect(html.contains("rel=0"))
        #expect(html.contains("modestbranding=1"))
        #expect(html.contains("playsinline=1"))
        #expect(html.contains("origin=\(ReaderWeb.baseOrigin)"))
        #expect(html.contains("allow=\"accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share\""))
    }

    @Test func rewriteEmbedsReplacesYouTubeIframe() throws {
        let doc = try SwiftSoup.parse("<iframe src=\"https://www.youtube.com/embed/abc12345678\"></iframe>")
        try EmbedRewriter.rewriteEmbeds(in: doc)
        let html = try doc.body()!.html()
        #expect(html.contains("youtube-nocookie.com/embed/abc12345678"))
        #expect(html.contains("youtube-embed-container"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/EmbedRewriterTests`
Expected: FAIL — `cannot find 'EmbedRewriter' in scope`.

- [ ] **Step 3: Implement `EmbedRewriter`**

Create `Yana/Aggregators/Utils/EmbedRewriter.swift`:

```swift
import Foundation
import SwiftSoup

/// Rewrites in-content video embeds to the exact markup the server's proxy served
/// (core/views/default.py), but pointing directly at the provider (no server hop).
enum EmbedRewriter {
    static func extractYouTubeID(from url: String) -> String? {
        let patterns = [
            #"youtu\.be/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/watch\?v=([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/embed/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/v/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/shorts/([A-Za-z0-9_-]{11,})"#,
        ]
        for p in patterns {
            if let r = url.range(of: p, options: .regularExpression) {
                let match = String(url[r])
                if let idRange = match.range(of: #"[A-Za-z0-9_-]{11,}$"#, options: .regularExpression) {
                    return String(match[idRange])
                }
            }
        }
        return nil
    }

    static func youTubeEmbedHTML(videoID: String) -> String {
        let params = "autoplay=0&loop=0&mute=0&controls=1&rel=0&modestbranding=1&playsinline=1&enablejsapi=1&origin=\(ReaderWeb.baseOrigin)"
        let src = "https://www.youtube-nocookie.com/embed/\(videoID)?\(params)"
        return """
        <div class="youtube-embed-container"><iframe src="\(src)" width="560" height="315" allowfullscreen allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin"></iframe></div>
        """
    }

    static func dailymotionEmbedHTML(videoID: String) -> String {
        let src = "https://geo.dailymotion.com/player.html?video=\(videoID)"
        return """
        <div class="dailymotion-embed-container"><iframe src="\(src)" width="560" height="315" allowfullscreen allow="autoplay; web-share" referrerpolicy="strict-origin-when-cross-origin"></iframe></div>
        """
    }

    static func rewriteEmbeds(in doc: Document) throws {
        for iframe in try doc.select("iframe") {
            let src = try iframe.attr("src")
            if let id = extractYouTubeID(from: src) {
                try iframe.parent()?.html("")   // clear wrapper if present
                let replacement = try SwiftSoup.parseBodyFragment(youTubeEmbedHTML(videoID: id)).body()!.child(0)
                try iframe.replaceWith(replacement)
            }
        }
    }

    /// Twitter/X via fxtwitter (direct API). Returns blockquote HTML or nil.
    static func tweetEmbedHTML(for url: String) async -> String? {
        guard let idRange = url.range(of: #"status/(\d+)"#, options: .regularExpression) else { return nil }
        let id = String(url[idRange]).replacingOccurrences(of: "status/", with: "")
        guard let apiURL = URL(string: "https://api.fxtwitter.com/status/\(id)") else { return nil }
        var req = URLRequest(url: apiURL)
        req.setValue("Yana/1.0", forHTTPHeaderField: "User-Agent")
        guard let data = try? await HTTPClient.fetchJSON(req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tweet = json["tweet"] as? [String: Any] else { return nil }
        let text = (tweet["text"] as? String ?? "").replacingOccurrences(of: "<", with: "&lt;")
        let author = (tweet["author"] as? [String: Any])?["screen_name"] as? String ?? ""
        return """
        <blockquote style="border-left: 3px solid #1d9bf0; padding: 12px 16px; margin: 1em 0; background: #f7f9fa;"><p><strong>@\(author)</strong> · <a href="\(url)">View on X</a></p><p>\(text)</p></blockquote>
        """
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/EmbedRewriterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/EmbedRewriter.swift YanaTests/EmbedRewriterTests.swift
git commit -m "feat: proxy-identical YouTube/Dailymotion/Twitter embed rewriting"
```

---

## Task 7: Reader constants + `ImageCompressor`

**Files:**
- Create: `Yana/Aggregators/Utils/ReaderWeb.swift`
- Create: `Yana/Aggregators/Utils/ImageCompressor.swift`
- Test: `YanaTests/ImageCompressorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ImageCompressorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("ImageCompressor")
struct ImageCompressorTests {
    private func pngData(_ side: Int) -> Data {
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!
    }

    @Test func compressesAndReturnsExtension() {
        let result = ImageCompressor.compress(pngData(2000), contentType: "image/png", isHeader: true)
        let out = try? #require(result)
        #expect(out != nil)
        #expect(["jpg", "png", "webp"].contains(out!.ext))
        #expect(out!.data.count > 0)
    }

    @Test func rejectsTinyImages() {
        // < min size guard (a few bytes is not a valid image)
        #expect(ImageCompressor.compress(Data([0x00, 0x01]), contentType: "image/png", isHeader: false) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageCompressorTests`
Expected: FAIL — `cannot find 'ImageCompressor' in scope`.

- [ ] **Step 3: Implement constants + compressor**

Create `Yana/Aggregators/Utils/ReaderWeb.swift`:

```swift
import Foundation

/// Stable values shared by the aggregation pipeline and the reader WebView.
enum ReaderWeb {
    /// The WebView renders article HTML under this fixed base origin (used by embeds' `origin` param).
    static let baseOrigin = "https://app.yana.local"
    /// Custom URL scheme for locally cached images (served by ImageSchemeHandler).
    static let imageScheme = "yana-img"
}
```

Create `Yana/Aggregators/Utils/ImageCompressor.swift`:

```swift
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Downscales + re-encodes images on-device (ImageIO), mirroring the server's Pillow step.
/// Header images are capped to ~1200px; output is JPEG (or PNG when transparency matters).
enum ImageCompressor {
    static func compress(_ data: Data, contentType: String?, isHeader: Bool) -> (data: Data, ext: String)? {
        guard data.count >= 100, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let maxDimension = isHeader ? 1200 : 2000
        let cgImage = downscale(image, maxDimension: maxDimension)

        let hasAlpha = cgImage.alphaInfo != .none && cgImage.alphaInfo != .noneSkipLast && cgImage.alphaInfo != .noneSkipFirst
        let useType: UTType = hasAlpha ? .png : .jpeg
        let ext = hasAlpha ? "png" : "jpg"

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, useType.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = useType == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, ext)
    }

    private static func downscale(_ image: CGImage, maxDimension: Int) -> CGImage {
        let w = image.width, h = image.height
        let longest = max(w, h)
        guard longest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(longest)
        let nw = Int(Double(w) * scale), nh = Int(Double(h) * scale)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageCompressorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/ReaderWeb.swift Yana/Aggregators/Utils/ImageCompressor.swift YanaTests/ImageCompressorTests.swift
git commit -m "feat: reader constants + ImageIO image compressor"
```

---

## Task 8: `ImageStore` actor + `rewriteImages`

**Files:**
- Create: `Yana/Aggregators/Utils/ImageStore.swift`
- Test: `YanaTests/ImageStoreTests.swift`

- [ ] **Step 1: Write the failing test (injected fetch — no network)**

Create `YanaTests/ImageStoreTests.swift`:

```swift
import Foundation
import UIKit
import SwiftSoup
import Testing
@testable import Yana

@Suite("ImageStore")
struct ImageStoreTests {
    private func pngData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300))
        return renderer.image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300)) }.pngData()!
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func storeDownloadsCompressesAndReturnsHash() async {
        let data = pngData()
        let store = ImageStore(directory: tempDir(), fetch: { _ in (data, "image/png") })
        let hash = await store.store(remoteURL: URL(string: "https://x.com/a.png")!, isHeader: false)
        let h = try? #require(hash)
        #expect(h != nil)
        #expect(FileManager.default.fileExists(atPath: await store.fileURL(forHash: h!).path))
    }

    @Test func rewriteImagesReplacesSrcWithScheme() async throws {
        let data = pngData()
        let store = ImageStore(directory: tempDir(), fetch: { _ in (data, "image/png") })
        let doc = try SwiftSoup.parse("<img src=\"https://x.com/a.png\"><p>hi</p>")
        try await rewriteImages(in: doc, store: store, baseURL: nil)
        let html = try doc.body()!.html()
        #expect(html.contains("\(ReaderWeb.imageScheme)://"))
        #expect(!html.contains("https://x.com/a.png"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageStoreTests`
Expected: FAIL — `cannot find 'ImageStore' in scope`.

- [ ] **Step 3: Implement `ImageStore` + `rewriteImages`**

Create `Yana/Aggregators/Utils/ImageStore.swift`:

```swift
import Foundation
import CryptoKit
import SwiftSoup

/// Downloads, compresses, and caches images as files keyed by content hash.
/// Article HTML references them via `yana-img://<hash>` (no remote URLs reach the WebView).
actor ImageStore {
    private let directory: URL
    private let fetch: @Sendable (URL) async throws -> (Data, String?)
    private var extensions: [String: String] = [:]   // hash -> file extension

    init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> (Data, String?) = { try await HTTPClient.fetchData($0) }) {
        self.directory = directory
        self.fetch = fetch
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let shared: ImageStore = {
        let dir = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("images") ?? FileManager.default.temporaryDirectory.appendingPathComponent("images")
        return ImageStore(directory: dir)
    }()

    /// Returns the content hash for a downloaded+compressed image, or nil on failure.
    func store(remoteURL: URL, isHeader: Bool) async -> String? {
        guard let (data, contentType) = try? await fetch(remoteURL),
              let compressed = ImageCompressor.compress(data, contentType: contentType, isHeader: isHeader) else { return nil }
        let hash = Self.hash(compressed.data)
        extensions[hash] = compressed.ext
        let url = fileURL(forHash: hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? compressed.data.write(to: url)
        }
        return hash
    }

    func fileURL(forHash hash: String) -> URL {
        let ext = extensions[hash] ?? "img"
        return directory.appendingPathComponent("\(hash).\(ext)")
    }

    func purgeOrphans(keepingHashes: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            if !keepingHashes.contains(name) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Walks every `<img>`, downloads via the store, and rewrites `src` to `yana-img://<hash>`.
/// Unresolved images are dropped (spec decision 3: no remote image URLs).
func rewriteImages(in doc: Document, store: ImageStore, baseURL: URL?) async throws {
    for img in try doc.select("img") {
        let raw = try [ "src", "data-src", "data-lazy-src" ].lazy
            .map { try img.attr($0) }.first { !$0.isEmpty } ?? ""
        guard !raw.isEmpty, !raw.hasPrefix("data:") else { try img.remove(); continue }
        let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL
        guard let resolved else { try img.remove(); continue }
        if let hash = await store.store(remoteURL: resolved, isHeader: false) {
            try img.attr("src", "\(ReaderWeb.imageScheme)://\(hash)")
            try img.removeAttr("data-src"); try img.removeAttr("data-lazy-src"); try img.removeAttr("srcset")
        } else {
            try img.remove()
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/Utils/ImageStore.swift YanaTests/ImageStoreTests.swift
git commit -m "feat: on-device image cache + img-src rewriting"
```

---

## Task 9: `ImageSchemeHandler` + reader WebView wiring

**Files:**
- Create: `Yana/Aggregators/Utils/ImageSchemeHandler.swift`
- Modify: `Yana/Views/ArticleWebView.swift`
- Test: `YanaTests/ImageSchemeHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ImageSchemeHandlerTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("ImageSchemeHandler")
struct ImageSchemeHandlerTests {
    @Test func hashExtractedFromSchemeURL() {
        let url = URL(string: "\(ReaderWeb.imageScheme)://abc123")!
        #expect(ImageSchemeHandler.hash(from: url) == "abc123")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageSchemeHandlerTests`
Expected: FAIL — `cannot find 'ImageSchemeHandler' in scope`.

- [ ] **Step 3: Implement the scheme handler**

Create `Yana/Aggregators/Utils/ImageSchemeHandler.swift`:

```swift
import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves `yana-img://<hash>` requests from the local image cache.
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: ImageStore

    init(store: ImageStore = .shared) { self.store = store }

    static func hash(from url: URL) -> String? {
        // yana-img://<hash> → host is the hash
        url.host ?? (url.absoluteString.components(separatedBy: "://").last)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let hash = Self.hash(from: url) else {
            task.didFailWithError(URLError(.badURL)); return
        }
        Task {
            let fileURL = await store.fileURL(forHash: hash)
            guard let data = try? Data(contentsOf: fileURL) else {
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            let ext = fileURL.pathExtension
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/jpeg"
            let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
            task.didReceive(response); task.didReceive(data); task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
```

- [ ] **Step 4: Wire the handler + base origin into the reader WebView**

In `Yana/Views/ArticleWebView.swift`, where the `WKWebViewConfiguration` is created, register the scheme handler before constructing the `WKWebView`, and load HTML with the base origin. Add:

```swift
let configuration = WKWebViewConfiguration()
configuration.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ReaderWeb.imageScheme)
```

And when loading content, use the base origin so embeds' `origin` param matches:

```swift
webView.loadHTMLString(fullHTML, baseURL: URL(string: ReaderWeb.baseOrigin))
```

(Also add the embed-container CSS to the reader's `<style>` — the 16:9 rules for
`.youtube-embed-container` / `.dailymotion-embed-container` from `core/views/default.py`.)

- [ ] **Step 5: Run test + full suite to verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ImageSchemeHandlerTests`
Expected: PASS.
Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (reader changes compile).

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Utils/ImageSchemeHandler.swift Yana/Views/ArticleWebView.swift YanaTests/ImageSchemeHandlerTests.swift
git commit -m "feat: yana-img scheme handler + reader WebView wiring"
```

---

## Task 10: `HeaderElementExtractor`

**Files:**
- Create: `Yana/Aggregators/Utils/HeaderElementExtractor.swift`
- Test: `YanaTests/HeaderElementExtractorTests.swift`

- [ ] **Step 1: Write the failing test (injected store)**

Create `YanaTests/HeaderElementExtractorTests.swift`:

```swift
import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("HeaderElementExtractor")
struct HeaderElementExtractorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300))
        let png = renderer.image { ctx in UIColor.green.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300)) }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    @Test func youTubeURLProducesEmbedHeader() async {
        let store = tempStore()
        let header = await HeaderElementExtractor.extract(
            articleURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "T", store: store, credentials: .init())
        #expect(header?.html.contains("youtube-embed-container") == true)
    }

    @Test func genericImageURLProducesCachedImageHeader() async {
        let store = tempStore()
        let header = await HeaderElementExtractor.extract(
            articleURL: "https://x.com/photo.jpg", title: "T", store: store, credentials: .init())
        #expect(header?.html.contains("\(ReaderWeb.imageScheme)://") == true)
        #expect(header?.dedupURL == "https://x.com/photo.jpg")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HeaderElementExtractorTests`
Expected: FAIL — `cannot find 'HeaderElementExtractor' in scope`.

- [ ] **Step 3: Implement the extractor (strategy chain)**

Create `Yana/Aggregators/Utils/HeaderElementExtractor.swift`:

```swift
import Foundation

/// The lead media for an article header: ready-to-insert HTML, plus the original image URL
/// (if any) so the body can de-dup it.
struct HeaderElement: Sendable { var html: String; var dedupURL: String? }

/// Strategy chain mirroring services/header_element: YouTube thumbnail/embed → generic image.
/// (Reddit-specific strategies live in the Reddit aggregator, Phase 4e.)
enum HeaderElementExtractor {
    static func extract(articleURL: String, title: String, store: ImageStore, credentials: AggregatorCredentials) async -> HeaderElement? {
        // 1. YouTube → embed header (no image download needed).
        if let id = EmbedRewriter.extractYouTubeID(from: articleURL) {
            return HeaderElement(html: "<header style=\"margin-bottom: 1.5em;\">\(EmbedRewriter.youTubeEmbedHTML(videoID: id))</header>", dedupURL: nil)
        }
        // 2. Generic lead image: only when the URL looks like an image.
        guard looksLikeImage(articleURL), let url = URL(string: articleURL),
              let hash = await store.store(remoteURL: url, isHeader: true) else { return nil }
        let html = ContentFormatter.headerImageHTML(src: "\(ReaderWeb.imageScheme)://\(hash)", alt: title)
        return HeaderElement(html: html, dedupURL: articleURL)
    }

    private static func looksLikeImage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { lower.contains($0) }
    }
}
```

(Full-page lead-image discovery — fetching the article and reading `og:image` — is added by
`FullWebsiteAggregator` in Phase 4c, which passes the discovered image URL here.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/HeaderElementExtractorTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Utils/HeaderElementExtractor.swift YanaTests/HeaderElementExtractorTests.swift
git commit -m "feat: header element extractor (YouTube + generic image)"
```

---

## Self-Review

**Spec coverage (4b scope, §3):** SwiftSoup dep (T1), HTTP fetch + skip (T2), RSS/Atom parser
(T3), HTML utils incl. sanitize/extract/removeEmpty/removeImageByURL (T4), content wrapper (T5),
proxy-identical embed rewriting incl. Twitter (T6), reader constants + ImageIO compression (T7),
image cache + src rewriting (T8), custom scheme handler + WebView wiring (T9), header element
(T10). All §3 items covered. (`og:image` full-page discovery deferred to 4c by design; Reddit
header strategies to 4e.)

**Placeholders:** none — each step has complete code or an exact command + expected output.

**Type consistency:** the interface-contract signatures are used verbatim by each task
(`HTTPClient.fetchData`, `FeedParser.parse`, `HTMLUtils.*`, `ContentFormatter.format`,
`EmbedRewriter.*`, `ReaderWeb.baseOrigin`/`imageScheme`, `ImageCompressor.compress`,
`ImageStore(directory:fetch:)` + `store`/`fileURL`/`purgeOrphans`, `rewriteImages`,
`ImageSchemeHandler`, `HeaderElement`/`HeaderElementExtractor.extract`). These match the
references in plans 4c–4g.
