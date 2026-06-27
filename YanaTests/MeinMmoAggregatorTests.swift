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

    // Mein-MMO Dailymotion videos (div.wp-block-mmo-video, dmVideoId in an inline script) are
    // rendered as a click-to-play facade — the same treatment as YouTube — rather than dropped.
    // The live player iframe is stashed in the facade's data-embed attribute; the video title
    // becomes a caption.
    @Test func includesDailymotionAsFacadeAndRemovesPaginationMarkers() async throws {
        let first = """
        <html><body><div class="gp-entry-content"><p>Intro</p>\
        <div class="wp-block-mmo-video"><div class="title">Cool Trailer</div>\
        <script>window.Mmo.functions.renderDmPlayer({ dmVideoId: 'x9yt07o' });</script></div>\
        <p><em>Weiter geht es auf Seite 2.</em></p>\
        <div class="wp-block-mmo-recirculation-box">related junk</div>\
        </div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        // Dailymotion is rendered as a play-button facade carrying the player URL + video id.
        #expect(a.content.contains("dailymotion-facade"))
        #expect(a.content.contains("dailymotion-play"))
        #expect(a.content.contains("geo.dailymotion.com/player.html?video=x9yt07o"))
        // The video title is preserved as a caption.
        #expect(a.content.contains("Cool Trailer"))
        // Other content and removals still work.
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

    // Mein-MMO wraps YouTube embeds in the `wbd-embed-privacy` (GDPR consent) plugin: the live
    // <iframe> exists only entity-encoded inside a `data-embed-content` attribute, while the visible
    // DOM is a consent placeholder plus a plain "Link zum YouTube Inhalt" anchor. The aggregator must
    // find that anchor and rewrite the figure to a play-button facade — and must NOT leak the consent
    // overlay's opt-out text ("Anzeige von YouTube Inhalten … widerrufen") into the output. Exercised
    // through the multi-page merge path, where the figure lives on a fetched secondary page.
    @Test func convertsEmbedPrivacyWrappedYouTube() async throws {
        let figurePage = #"""
        <html><body><div class="entry-content"><p>Intro before</p><figure class="wp-block-embed is-type-video is-provider-youtube wp-block-embed-youtube wp-embed-aspect-16-9 wp-has-aspect-ratio"><div class="wp-block-embed__wrapper">
                <div class="embed-privacy-container embed-youtube">
                    <div class="embed-privacy-overlay" data-embed-provider="youtube">
                        <div class="embed-privacy-inner">
                        <div class="logo"></div>
                        <div class="title">Empfohlener redaktioneller Inhalt</div>
                        <p>An dieser Stelle findest du einen externen Inhalt von YouTube, der den Artikel ergänzt.</p>
                        <button>YouTube Inhalt anzeigen</button>
                        <div class="notice">
                            Ich bin damit einverstanden, dass mir externe Inhalte angezeigt werden.
                            Mehr dazu in unserer <a href="https://mein-mmo.de/datenschutzerklaerung/" target="_blank" rel="nofollow noopener">Datenschutzerklärung</a>.
                        </div>
                        </div>
                    </div>
                    <div class="embed-privacy-content" data-embed-content="		&lt;div class=&quot;wbd-embed&quot;&gt;
                &lt;div class=&quot;wbd-embed-wrapper wbd-embed-aspect-16-9&quot;&gt;&lt;iframe title=&quot;Death Note (Anime-Trailer)&quot; width=&quot;720&quot; height=&quot;405&quot; src=&quot;https://www.youtube-nocookie.com/embed/9BxbETVKSLk?feature=oembed&quot; frameborder=&quot;0&quot; allowfullscreen&gt;&lt;/iframe&gt;&lt;/div&gt;
                    &lt;div class=&quot;embed-privacy-optout&quot;&gt;
                        Anzeige von YouTube Inhalten &lt;a href=&quot;javascript:void(0);&quot; data-embed-provider=&quot;youtube&quot; data-embed-status=&quot;1&quot; onClick=&quot;window.wbdEmbedPrivacy.optout(this);&quot;&gt;widerrufen&lt;/a&gt;.
                        &lt;span class=&quot;notice&quot;&gt;Mehr dazu in unserer &lt;a href=&quot;https://mein-mmo.de/datenschutzerklaerung/&quot; target=&quot;_blank&quot; rel=&quot;nofollow noopener&quot;&gt;Datenschutzerklärung&lt;/a&gt;.&lt;/span&gt;
                    &lt;/div&gt;
            &lt;/div&gt;
            ">
                        Link zum <a href="https://www.youtube.com/watch?v=9BxbETVKSLk" target="_blank" rel="nofollow noopener">YouTube Inhalt</a>
                </div>
            </div>
        </div></figure><p>Outro after</p></div></body></html>
        """#
        // Put the figure on page 2 and fetch it via pagination, mirroring reality.
        let page1 = #"""
        <html><body><div class="entry-content"><p>Page one</p>\
        <div class="page-links"><a class="post-page-numbers" href="https://mein-mmo.de/post-1/2/">2</a></div>\
        </div></body></html>
        """#
        let agg = StubMmo(first: page1, extraPages: ["https://mein-mmo.de/post-1/2/": figurePage],
                          options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        // The consent-wrapped iframe is rewritten to a play-button facade pointing at the real video…
        #expect(a.content.contains("youtube-facade"))
        #expect(a.content.contains("youtube-nocookie.com/embed/9BxbETVKSLk"))
        // …and the consent overlay's opt-out text never reaches the output.
        #expect(!a.content.contains("Anzeige von YouTube Inhalten"))
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
            // Link text "Seite 2" is intentionally non-numeric so detection relies solely
            // on the ?page=N / trailing-path URL regex, not on Int(text) parsing.
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

    @Test func extractsHeaderImageFromOgImage() async throws {
        // The featured/lead image is declared via <meta property="og:image"> and must be
        // rendered as a header element above the article body (parity with other scrapers).
        let first = """
        <html><head><meta property="og:image" content="https://mein-mmo.de/img/cover.jpg"></head>\
        <body><div class="entry-content"><p>Article text</p></div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("<header"))
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))
        #expect(a.content.contains("Article text"))
    }

    // MARK: - wpDiscuz comment extraction

    /// Wraps article body + a wpDiscuz thread (two comments, the second a nested reply) into a page.
    private func pageWithComments() -> String {
        """
        <html><body>
        <div class="entry-content"><p>Article body text</p></div>
        <div id="wpdcom" class="wpdiscuz_unauth"><div class="wpd-thread-list">
          <div id='wpd-comm-1_0' class='comment wpd-comment wpd_comment_level-1'><div class="wpd-comment-wrap">
            <div id="comment-1" class="wpd-comment-right">
              <div class="wpd-comment-header">
                <div class="wpd-comment-author "><a href="https://mein-mmo.de/user/alice/">Alice</a><span class="wpd-user-nicename">(@alice)</span></div>
                <div class="wpd-comment-date" title="27. Juni 2026 12:45"><i class="far fa-clock"></i> vor 2 Stunden</div>
              </div>
              <div class="wpd-comment-text"><p>First comment body</p></div>
            </div>
            <div class="wpd-comment wpd_comment_level-2"><div class="wpd-comment-wrap">
              <div id="comment-2" class="wpd-comment-right">
                <div class="wpd-comment-author "><a href="https://mein-mmo.de/user/bob/">Bob</a></div>
                <div class="wpd-comment-date" title="27. Juni 2026 13:00">vor 1 Stunde</div>
                <div class="wpd-comment-text"><p>A nested reply</p></div>
              </div>
            </div></div>
          </div></div>
        </div></div>
        </body></html>
        """
    }

    @Test func extractsWpDiscuzComments() async throws {
        let agg = StubMmo(first: pageWithComments(), extraPages: [:],
                          options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        // A comments section is emitted with both the top-level comment and the nested reply.
        #expect(a.content.contains("article-comments"))
        #expect(a.content.contains("Alice"))
        #expect(a.content.contains("First comment body"))
        #expect(a.content.contains("Bob"))
        #expect(a.content.contains("A nested reply"))
        // The absolute date from the `title` attribute is preferred over the relative text.
        #expect(a.content.contains("27. Juni 2026 12:45"))
        #expect(!a.content.contains("vor 2 Stunden"))
        // Each comment anchors to its own #comment-<id>.
        #expect(a.content.contains("#comment-1"))
        #expect(a.content.contains("#comment-2"))
        // The article body is still present.
        #expect(a.content.contains("Article body text"))
    }

    @Test func respectsMaxComments() async throws {
        let agg = StubMmo(first: pageWithComments(), extraPages: [:],
                          options: { var o = MeinMmoOptions(); o.maxComments = 1; return o }(),
                          store: tempStore())
        let a = try await enrichOne(agg)
        #expect(a.content.contains("First comment body"))
        #expect(!a.content.contains("A nested reply"))
    }

    @Test func disablingCommentsOmitsSection() async throws {
        let agg = StubMmo(first: pageWithComments(), extraPages: [:],
                          options: { var o = MeinMmoOptions(); o.includeComments = false; return o }(),
                          store: tempStore())
        let a = try await enrichOne(agg)
        #expect(!a.content.contains("article-comments"))
        #expect(!a.content.contains("First comment body"))
        #expect(a.content.contains("Article body text"))
    }

    @Test func noCommentSectionWhenThreadAbsent() async throws {
        let first = """
        <html><body><div class="entry-content"><p>Body without comments</p></div></body></html>
        """
        let agg = StubMmo(first: first, extraPages: [:], options: MeinMmoOptions(), store: tempStore())
        let a = try await enrichOne(agg)
        #expect(!a.content.contains("article-comments"))
        #expect(a.content.contains("Body without comments"))
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
