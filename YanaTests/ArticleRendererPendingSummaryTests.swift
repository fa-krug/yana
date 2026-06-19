import Foundation
import Testing
@testable import Yana

@MainActor
struct ArticleRendererPendingSummaryTests {
    @Test func pendingInsertsPlaceholderWhenNoSummaryYet() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "", summaryPending: true)
        #expect(html.contains("yana-summary-pending"))
        let placeholderRange = html.range(of: "yana-summary-pending")
        let bodyRange = html.range(of: "<p>body</p>")
        #expect(placeholderRange != nil && bodyRange != nil)
        #expect(placeholderRange!.lowerBound < bodyRange!.lowerBound)
    }

    @Test func realSummaryWinsOverPending() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "real", summaryPending: true)
        #expect(html.contains("real"))
        #expect(!html.contains("yana-summary-pending"))
    }

    @Test func notPendingAndNoSummaryIsContentOnly() {
        let html = ArticleRenderer.composeBody(content: "<p>body</p>", summary: "", summaryPending: false)
        #expect(html == "<p>body</p>")
    }
}
