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
        // New layout: div.page-links with a.post-page-numbers
        let first = """
        <html><body><div class="entry-content"><p>Page one body</p>\
        <div class="page-links"><a class="post-page-numbers" href="https://mein-mmo.de/post-1/2/">2</a></div>\
        </div></body></html>
        """
        let page2 = "<html><body><div class=\"entry-content\"><p>Page two body</p></div></body></html>"
        let agg = StubMmo(first: first, extraPages: ["https://mein-mmo.de/post-1/2/": page2],
                          options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Page one body"))
        #expect(a.content.contains("Page two body"))
    }

    @Test func disablingCombineKeepsFirstPageOnly() async throws {
        // New layout: div.page-links with a.post-page-numbers
        let first = """
        <html><body><div class="entry-content"><p>Only page one</p>\
        <div class="page-links"><a class="post-page-numbers" href="https://mein-mmo.de/post-1/2/">2</a></div>\
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: ["https://mein-mmo.de/post-1/2/": "<div class=\"entry-content\"><p>Page two</p></div>"],
                          options: { var o = MeinMmoOptions(); o.combinePages = false; return o }(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Only page one"))
        #expect(!a.content.contains("Page two"))
    }

    // Server commit 1e3afd3 excludes dailymotion embeds from MeinMMO output entirely:
    // process_dailymotion_blocks() builds div.dailymotion-embed-container but
    // selectors_to_remove immediately decomposes it. iOS mirrors this: the conversion step
    // runs first, then .dailymotion-embed-container is stripped by selectorsToRemove.
    @Test func excludesDailymotionAndRemovesPaginationMarkers() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Intro</p>\
        <div class="wp-block-mmo-video"><script>var x = { dmVideoId: 'x9yt07o' };</script></div>\
        <p><em>Weiter geht es auf Seite 2.</em></p>\
        <div class="wp-block-mmo-recirculation-box">related junk</div>\
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        // Dailymotion content must NOT appear in final output (server commit 1e3afd3)
        #expect(!a.content.contains("dailymotion-embed-container"))
        #expect(!a.content.contains("dailymotion.com"))
        #expect(!a.content.contains("x9yt07o"))
        // Other content and removals still work
        #expect(a.content.contains("Intro"))
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

    @Test func extractsContentFromRedesignedEntryContentClass() async throws {
        // Mein-MMO migrated off the GeneratePress theme: the content container is now
        // `div.entry-content`, not `div.gp-entry-content`. The body must still be extracted.
        let first = """
        <html><body><div class="entry-content"><p>Redesigned body text</p></div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Redesigned body text"))
    }

    @Test func identifierChoicesHasSingleFeed() {
        #expect(MeinMmoAggregator.identifierChoices.count == 1)
    }

    // MARK: - New-layout selector tests (server commits 818952b, cbc0ad1)

    @Test func detectsPaginationOnNewLayout() {
        // New layout uses div.page-links > a.post-page-numbers / span.post-page-numbers
        let html = """
        <html><body><div class="entry-content">
          <p>Body text</p>
          <div class="page-links">
            <span class="post-page-numbers current">1</span>
            <a class="post-page-numbers" href="https://mein-mmo.de/post-1/2/">2</a>
            <a class="post-page-numbers" href="https://mein-mmo.de/post-1/3/">3</a>
          </div>
        </div></body></html>
        """
        let agg = StubMmo(first: html, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let pages = agg.detectPagination(html: html)
        #expect(pages == [1, 2, 3])
    }

    @Test func detectsPaginationFromURLPatternOnNewLayout() {
        // Verify URL-based page detection also works with a.post-page-numbers
        let html = """
        <html><body><div class="entry-content">
          <div class="page-links">
            <a class="post-page-numbers" href="https://mein-mmo.de/artikel/2/">Seite 2</a>
          </div>
        </div></body></html>
        """
        let agg = StubMmo(first: html, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let pages = agg.detectPagination(html: html)
        #expect(pages.contains(1))   // always seeded
        #expect(pages.contains(2))   // extracted from URL pattern
    }

    @Test func noPaginationWhenNoPageLinksContainer() {
        // div.page-links absent → single-page article
        let html = """
        <html><body><div class="entry-content"><p>Single page</p></div></body></html>
        """
        let agg = StubMmo(first: html, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let pages = agg.detectPagination(html: html)
        #expect(pages == [1])
    }

    @Test func combinesNewLayoutPagesAndStripsPageLinks() async throws {
        // Verify full enrich() path: new-layout pagination is detected and page-links div removed
        let first = """
        <html><body><div class="entry-content"><p>Page one body</p>\
        <div class="page-links">\
        <span class="post-page-numbers current">1</span>\
        <a class="post-page-numbers" href="https://mein-mmo.de/post-1/2/">2</a>\
        </div></div></body></html>
        """
        let page2 = """
        <html><body><div class="entry-content"><p>Page two body</p></div></body></html>
        """
        let agg = StubMmo(first: first,
                          extraPages: ["https://mein-mmo.de/post-1/2/": page2],
                          options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("Page one body"))
        #expect(a.content.contains("Page two body"))
        // page-links div must be stripped from output
        #expect(!a.content.contains("page-links"))
    }

    @Test func removesSourcesWrapperAndFeedbackBox() async throws {
        let first = """
        <html><body><div class="entry-content">
          <p>Article text</p>
          <div class="sources-wrapper"><a href="#">Source</a></div>
          <div class="feedback-box">Was this helpful?</div>
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(!a.content.contains("sources-wrapper"))
        #expect(!a.content.contains("feedback-box"))
        #expect(!a.content.contains("Was this helpful?"))
        #expect(a.content.contains("Article text"))
    }

    @Test func removesHubBox() async throws {
        // server commit cbc0ad1: div.wp-block-mmo-hub-box must be stripped
        let first = """
        <html><body><div class="entry-content">
          <p>Main content</p>
          <div class="wp-block-mmo-hub-box"><p>Hub box junk</p></div>
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(!a.content.contains("wp-block-mmo-hub-box"))
        #expect(!a.content.contains("Hub box junk"))
        #expect(a.content.contains("Main content"))
    }
}
