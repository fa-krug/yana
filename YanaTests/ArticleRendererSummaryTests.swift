import Foundation
import Testing
@testable import Yana

@MainActor
struct ArticleRendererSummaryTests {
    @Test func bodyIncludesSummaryBlockWhenPresent() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "the summary")
        #expect(html.contains("yana-summary"))
        #expect(html.contains("the summary"))
        // Summary appears before the body content.
        let summaryRange = html.range(of: "the summary")
        let bodyRange = html.range(of: "<p>body</p>")
        #expect(summaryRange != nil && bodyRange != nil)
        #expect(summaryRange!.lowerBound < bodyRange!.lowerBound)
    }

    @Test func bodyIsContentOnlyWhenSummaryEmpty() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "")
        #expect(html == "<p>body</p>")
    }

    @Test func summarySitsBetweenLeadImageAndBodyText() {
        let content = "<header><img src=\"x\"></header>\n\n<section><p>body</p></section>"
        let html = ArticleRenderer.composeBody(content: content, summary: "the summary")
        let imageRange = html.range(of: "<img")
        let summaryRange = html.range(of: "the summary")
        let bodyRange = html.range(of: "<p>body</p>")
        #expect(imageRange != nil && summaryRange != nil && bodyRange != nil)
        // image first, then summary, then body text.
        #expect(imageRange!.lowerBound < summaryRange!.lowerBound)
        #expect(summaryRange!.lowerBound < bodyRange!.lowerBound)
    }

    @Test func summaryPrependsWhenNoLeadingHeader() {
        let html = ArticleRenderer.composeBody(content: "<section><p>body</p></section>", summary: "the summary")
        let summaryRange = html.range(of: "the summary")
        let bodyRange = html.range(of: "<p>body</p>")
        #expect(summaryRange != nil && bodyRange != nil)
        #expect(summaryRange!.lowerBound < bodyRange!.lowerBound)
    }
}
