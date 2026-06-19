import Testing
@testable import Yana

@Suite("ReaderMenuBuilder")
struct ReaderMenuBuilderTests {
    @Test func allVisibleWhenEverythingPresent() {
        let c = ReaderMenuBuilder.config(hasURL: true, hasFeed: true, aiReady: true)
        #expect(c == ReaderMenuConfig(showCopyLink: true, showSummarize: true, showGoToFeed: true))
    }

    @Test func copyLinkHiddenWithoutURL() {
        #expect(ReaderMenuBuilder.config(hasURL: false, hasFeed: true, aiReady: true).showCopyLink == false)
    }

    @Test func summarizeHiddenWhenAINotReady() {
        #expect(ReaderMenuBuilder.config(hasURL: true, hasFeed: true, aiReady: false).showSummarize == false)
    }

    @Test func goToFeedHiddenWithoutFeed() {
        #expect(ReaderMenuBuilder.config(hasURL: true, hasFeed: false, aiReady: true).showGoToFeed == false)
    }
}
