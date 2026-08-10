import Testing
@testable import Yana

@Suite("ReaderMenuBuilder")
struct ReaderMenuBuilderTests {
    @Test func allVisibleWhenEverythingPresent() {
        let c = ReaderMenuBuilder.config(hasURL: true, aiReady: true, hasServerArticle: true)
        #expect(c == ReaderMenuConfig(showReload: true, showCopyLink: true, showSummarize: true, showOpenOnServer: true))
    }

    @Test func copyLinkHiddenWithoutURL() {
        #expect(ReaderMenuBuilder.config(hasURL: false, aiReady: true, hasServerArticle: true).showCopyLink == false)
    }

    @Test func summarizeHiddenWhenAINotReady() {
        #expect(ReaderMenuBuilder.config(hasURL: true, aiReady: false, hasServerArticle: true).showSummarize == false)
    }

    @Test func reloadAndOpenOnServerHiddenWhenNotAvailable() {
        let c = ReaderMenuBuilder.config(hasURL: true, aiReady: true, hasServerArticle: false)
        #expect(c.showReload == false)
        #expect(c.showOpenOnServer == false)
    }
}
