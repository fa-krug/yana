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
}
