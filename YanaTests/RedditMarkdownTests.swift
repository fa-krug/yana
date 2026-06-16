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
}
