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
