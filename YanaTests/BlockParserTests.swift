import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("BlockParser")
struct BlockParserTests {

    @Test func mapsParagraphsHeadingsAndInlineStyles() {
        let html = "<h2>Title</h2><p>Hello <strong>bold</strong> and <em>italic</em>.</p>"
        let blocks = BlockParser.blocks(fromHTML: html)
        #expect(blocks.count == 2)
        guard case let .heading(level, headingRuns) = blocks[0] else { Issue.record("expected heading"); return }
        #expect(level == 2)
        #expect(headingRuns.map(\.text).joined() == "Title")
        guard case let .paragraph(runs) = blocks[1] else { Issue.record("expected paragraph"); return }
        #expect(runs.contains { $0.text == "bold" && $0.styles.contains(.bold) })
        #expect(runs.contains { $0.text == "italic" && $0.styles.contains(.italic) })
    }

    @Test func resolvesRelativeLinksAgainstBaseURL() {
        let html = #"<p>See <a href="/path">here</a>.</p>"#
        let blocks = BlockParser.blocks(fromHTML: html, baseURL: URL(string: "https://example.com/article"))
        guard case let .paragraph(runs) = blocks.first else { Issue.record("expected paragraph"); return }
        let link = runs.first { $0.text == "here" }?.link
        #expect(link == "https://example.com/path")
    }

    @Test func mapsListsImagesCodeAndDivider() {
        let html = """
        <ul><li>one</li><li>two</li></ul>
        <img src="yana-img://abc123">
        <pre>let x = 1</pre>
        <hr>
        """
        let blocks = BlockParser.blocks(fromHTML: html)
        guard case let .list(ordered, items) = blocks.first(where: { if case .list = $0 { return true }; return false }) ?? .divider else {
            Issue.record("expected list"); return
        }
        #expect(ordered == false)
        #expect(items.count == 2)
        #expect(blocks.contains { if case .image(let ref, _) = $0 { return ref == "yana-img://abc123" }; return false })
        #expect(blocks.contains { if case .codeBlock = $0 { return true }; return false })
        #expect(blocks.contains { if case .divider = $0 { return true }; return false })
    }

    @Test func dropsTablesAndUnknownChrome() {
        let html = "<table><tr><td>cell</td></tr></table><p>kept</p>"
        let blocks = BlockParser.blocks(fromHTML: html)
        #expect(blocks.count == 1)
        guard case let .paragraph(runs) = blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(runs.map(\.text).joined() == "kept")
    }

    @Test func recognizesYouTubeEmbedFacade() {
        // Mirrors EmbedRewriter's facade after class sanitization (class → data-sanitized-class).
        let html = """
        <div data-sanitized-class="youtube-embed-container">
          <div data-sanitized-class="youtube-facade" data-embed="<iframe src=&quot;https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&quot;></iframe>">
            <img data-sanitized-class="youtube-poster" src="yana-img://poster1">
          </div>
        </div>
        """
        let blocks = BlockParser.blocks(fromHTML: html)
        guard case let .embed(embed) = blocks.first else { Issue.record("expected embed, got \(blocks)"); return }
        #expect(embed.provider == .youtube)
        #expect(embed.externalURL == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(embed.thumbnailRef == "yana-img://poster1")
    }

    @Test func recognizesHostedVideoAsInlineVideoEmbed() {
        // Mirrors RedditAggregator.makeVideoHTML / TagesschauAggregator: a Reddit-hosted (v.redd.it)
        // video is emitted as an HTML5 <video> with a <source> stream and a cached poster. It must
        // survive HTML→blocks conversion as a playable .video embed (not be dropped as chrome).
        let html = """
        <header><video controls playsinline preload="metadata" poster="yana-img://poster9">
        <source src="https://v.redd.it/abc123/HLSPlaylist.m3u8" type="application/vnd.apple.mpegurl">
        Your browser does not support the video element.</video></header>
        """
        let blocks = BlockParser.blocks(fromHTML: html)
        guard case let .embed(embed) = blocks.first else { Issue.record("expected video embed, got \(blocks)"); return }
        #expect(embed.provider == .video)
        #expect(embed.externalURL == "https://v.redd.it/abc123/HLSPlaylist.m3u8")
        #expect(embed.thumbnailRef == "yana-img://poster9")
        // The <video> element's plain-text fallback must not leak into the body as a paragraph.
        #expect(!BlockParser.plainText(blocks).contains("does not support"))
    }

    @Test func hostedVideoWithoutSourceUsesElementSrc() {
        let html = #"<video src="https://v.redd.it/xyz/DASH_720.mp4"></video>"#
        let blocks = BlockParser.blocks(fromHTML: html)
        guard case let .embed(embed) = blocks.first else { Issue.record("expected video embed, got \(blocks)"); return }
        #expect(embed.provider == .video)
        #expect(embed.externalURL == "https://v.redd.it/xyz/DASH_720.mp4")
        #expect(embed.thumbnailRef == nil)
    }

    @Test func recognizesTweetBlockquoteAsEmbed() {
        let html = #"<blockquote><p><strong>@nasa</strong> · <a href="https://x.com/nasa/status/123">View on X</a></p><p>Hello universe</p></blockquote>"#
        let blocks = BlockParser.blocks(fromHTML: html)
        guard case let .embed(embed) = blocks.first else { Issue.record("expected tweet embed"); return }
        #expect(embed.provider == .tweet)
        #expect(embed.externalURL == "https://x.com/nasa/status/123")
    }

    @Test func plainTextFlattensVisibleText() {
        let html = "<h1>Heading</h1><p>First <strong>para</strong>.</p><ul><li>item</li></ul>"
        let blocks = BlockParser.blocks(fromHTML: html)
        let text = BlockParser.plainText(blocks)
        #expect(text.contains("Heading"))
        #expect(text.contains("First para."))
        #expect(text.contains("item"))
        // No HTML markup leaks into the search/speech surface.
        #expect(!text.contains("<"))
    }

    @Test func emptyHTMLProducesNoBlocks() {
        #expect(BlockParser.blocks(fromHTML: "").isEmpty)
        #expect(BlockParser.blocks(fromHTML: "   \n  ").isEmpty)
    }

    @Test func blocksRoundTripThroughJSON() throws {
        let blocks = BlockParser.blocks(fromHTML: "<p>Hello <a href=\"https://e.com\">link</a></p>")
        let data = try JSONEncoder().encode(blocks)
        let decoded = try JSONDecoder().decode([Block].self, from: data)
        #expect(decoded == blocks)
    }
}
