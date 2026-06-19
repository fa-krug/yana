import Testing
@testable import Yana

@Suite("ReaderMenuBuilder")
struct ReaderMenuBuilderTests {
    @Test func allVisibleWhenEverythingPresent() {
        let c = ReaderMenuBuilder.config(hasURL: true, aiReady: true)
        #expect(c == ReaderMenuConfig(showCopyLink: true, showSummarize: true))
    }

    @Test func copyLinkHiddenWithoutURL() {
        #expect(ReaderMenuBuilder.config(hasURL: false, aiReady: true).showCopyLink == false)
    }

    @Test func summarizeHiddenWhenAINotReady() {
        #expect(ReaderMenuBuilder.config(hasURL: true, aiReady: false).showSummarize == false)
    }
}
