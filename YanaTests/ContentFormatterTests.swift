import Foundation
import Testing
@testable import Yana

@Suite("ContentFormatter")
struct ContentFormatterTests {
    @Test func wrapsContentWithSectionAndNoSourceFooter() {
        let out = ContentFormatter.format(content: "<p>body</p>", title: "T", url: "https://x.com/1", headerHTML: nil, commentsHTML: nil)
        #expect(out.contains("<section data-sanitized-class=\"article-content\"><p>body</p></section>"))
        // The source link now lives in the reader toolbar, not the body.
        #expect(!out.contains("Source:"))
        #expect(!out.contains("https://x.com/1"))
    }

    @Test func includesHeaderAndComments() {
        let out = ContentFormatter.format(content: "<p>b</p>", title: "T", url: "u", headerHTML: "<header>H</header>", commentsHTML: "<p>c</p>")
        #expect(out.contains("<header>H</header>"))
        #expect(out.contains("data-sanitized-class=\"article-comments\""))
    }

    @Test func escapesUnsafeCharacters() {
        let out = ContentFormatter.escapeHTML("https://e.com/?a=1&b=<script>")
        #expect(!out.contains("<script>"))
        #expect(out.contains("&amp;"))
        #expect(out.contains("&lt;script&gt;"))
    }
}
