import Foundation
import Testing
@testable import Yana

@Suite("RedditMarkdown")
struct RedditMarkdownTests {
    @Test func emptyInputReturnsEmpty() {
        #expect(RedditMarkdown.toHTML("") == "")
    }

    @Test func paragraphsBecomeParagraphTags() {
        let html = RedditMarkdown.toHTML("First line.\n\nSecond line.")
        #expect(html.contains("<p>First line.</p>"))
        #expect(html.contains("<p>Second line.</p>"))
    }

    @Test func markdownLinkBecomesAnchorOpeningNewTab() {
        let html = RedditMarkdown.toHTML("See [the docs](https://example.com/x).")
        #expect(html.contains("href=\"https://example.com/x\""))
        #expect(html.contains(">the docs</a>"))
        #expect(html.contains("target=\"_blank\""))
        #expect(html.contains("rel=\"noopener\""))
    }

    @Test func boldAndItalicConvert() {
        let html = RedditMarkdown.toHTML("This is **bold** and *italic*.")
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
    }

    @Test func strikethroughAndSpoilerAndSuperscript() {
        #expect(RedditMarkdown.toHTML("~~gone~~").contains("<del>gone</del>"))
        #expect(RedditMarkdown.toHTML(">!secret!<").contains("class=\"spoiler\""))
        #expect(RedditMarkdown.toHTML("E=mc^2").contains("<sup>2</sup>"))
        #expect(RedditMarkdown.toHTML("foot^(note here)").contains("<sup>note here</sup>"))
    }

    @Test func blockquoteAndUnorderedList() {
        let quote = RedditMarkdown.toHTML("> quoted text")
        #expect(quote.contains("<blockquote>"))
        #expect(quote.contains("quoted text"))
        let list = RedditMarkdown.toHTML("- one\n- two")
        #expect(list.contains("<ul>"))
        #expect(list.contains("<li>one</li>"))
        #expect(list.contains("<li>two</li>"))
    }

    @Test func bareURLGetsLinkified() {
        let html = RedditMarkdown.toHTML("visit https://example.com now")
        #expect(html.contains("<a href=\"https://example.com\""))
        #expect(html.contains("target=\"_blank\""))
    }

    @Test func previewReddItBecomesImage() {
        let html = RedditMarkdown.toHTML("https://preview.redd.it/abc.png?width=100")
        #expect(html.contains("<img"))
        #expect(html.contains("preview.redd.it/abc.png"))
    }

    @Test func previewImageLinkWithLabelDoesNotLeakAltText() {
        // A markdown preview-image link with a descriptive label must become a single,
        // well-formed <img>. Regression: the bare-URL pass used to re-match the freshly
        // created tag's own src, double-wrapping it and leaking `alt="...">` as visible text.
        let md = "[Werbung für AppleCare-Abdeckung in der macOS-Einstellungen-App]"
            + "(https://preview.redd.it/abc.png?width=640&s=hash)"
        let html = RedditMarkdown.toHTML(md)
        #expect(!html.contains("<img src=\"<img"))                 // no nested/double-wrapped img
        #expect(html.components(separatedBy: "<img").count == 2)    // exactly one <img>
        #expect(html.contains("alt=\"Werbung für AppleCare-Abdeckung in der macOS-Einstellungen-App\""))
    }

    @Test func giphyEmbedBecomesImage() {
        let html = RedditMarkdown.toHTML("![gif](giphy|Vy9bLZxNutIlLuNXOZ)")
        #expect(html.contains("<img"))
        #expect(html.contains("media.giphy.com/media/Vy9bLZxNutIlLuNXOZ/giphy.gif"))
        #expect(!html.contains("![gif]"))
        #expect(!html.contains("giphy|"))
    }

    @Test func giphyEmbedWithSizeSuffixBecomesImage() {
        let html = RedditMarkdown.toHTML("![gif](giphy|Vy9bLZxNutIlLuNXOZ|downsized)")
        #expect(html.contains("media.giphy.com/media/Vy9bLZxNutIlLuNXOZ/giphy.gif"))
        #expect(!html.contains("downsized"))
    }

    @Test func escapesRawHTMLInBody() {
        let html = RedditMarkdown.toHTML("Hello <script>alert(1)</script> world")
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test func escapesEventHandlerInjection() {
        let html = RedditMarkdown.toHTML("text <img src=x onerror=alert(1)>")
        #expect(!html.contains("<img src=x onerror"))   // raw tag neutralized
        #expect(html.contains("&lt;img"))
    }

    @Test func backslashEscapedDashIsNotAListAndDropsBackslash() {
        // Reddit users write "\-" to get a literal dash that isn't a list bullet.
        let html = RedditMarkdown.toHTML("\\- Through the door\n\n\\- Past the desk")
        #expect(!html.contains("<ul>"))
        #expect(!html.contains("<li>"))
        #expect(!html.contains("\\-"))
        #expect(html.contains("- Through the door"))
        #expect(html.contains("- Past the desk"))
    }

    @Test func backslashEscapedPunctuationStaysLiteral() {
        let star = RedditMarkdown.toHTML("\\*not italic\\*")
        #expect(!star.contains("<em>"))
        #expect(star.contains("*not italic*"))
        // Backslash before non-escapable char is left untouched.
        #expect(RedditMarkdown.toHTML("C:\\path").contains("C:\\path"))
        // Double backslash collapses to a single literal backslash.
        #expect(RedditMarkdown.toHTML("a\\\\b").contains("a\\b"))
    }

    @Test func existingHTMLEntitiesArePreserved() {
        // raw_json=1 returns user-typed entities verbatim; keep them so the WebView decodes them.
        #expect(RedditMarkdown.toHTML("a&#x200B;b").contains("&#x200B;"))
        #expect(!RedditMarkdown.toHTML("a&#x200B;b").contains("&amp;#x200B;"))
        #expect(RedditMarkdown.toHTML("it&#39;s").contains("&#39;"))
        #expect(RedditMarkdown.toHTML("a&nbsp;b").contains("&nbsp;"))
        // Already-encoded ampersand is not double-escaped.
        #expect(RedditMarkdown.toHTML("a &amp; b").contains("&amp;"))
        #expect(!RedditMarkdown.toHTML("a &amp; b").contains("&amp;amp;"))
    }

    @Test func bareAmpersandIsStillEscaped() {
        #expect(RedditMarkdown.toHTML("R&D budget").contains("R&amp;D"))
    }

    @Test func escapingDoesNotBreakMarkdownStructure() {
        // blockquote, spoiler, bold, and a link all still work through the escaped path
        #expect(RedditMarkdown.toHTML("> quoted").contains("<blockquote>"))
        #expect(RedditMarkdown.toHTML(">!secret!<").contains("class=\"spoiler\""))
        #expect(RedditMarkdown.toHTML("**bold**").contains("<strong>bold</strong>"))
        let link = RedditMarkdown.toHTML("[docs](https://e.com/x)")
        #expect(link.contains("href=\"https://e.com/x\""))
        #expect(link.contains(">docs</a>"))
    }
}
