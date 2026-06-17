import Testing
@testable import Yana

@Suite("ArticleHeaderLogo.imgTag")
struct ArticleHeaderLogoTests {
    @Test func emitsImgForHash() {
        let tag = ArticleHeaderLogo.imgTag(logoHash: "abc123")
        #expect(tag.contains("class=\"feed-logo\""))
        #expect(tag.contains("\(ReaderWeb.imageScheme)://abc123"))
    }

    @Test func emptyWhenNoHash() {
        #expect(ArticleHeaderLogo.imgTag(logoHash: nil) == "")
    }
}
