import Foundation
import Testing
@testable import Yana

/// Locks in the denormalized `Article.leadImageRef` column: the reader warms an article's header
/// image ahead of a swipe by reading this cheap stored ref instead of decoding the whole `[Block]`
/// body just to peek at its first element. The `blocks` setter keeps it in sync.
@Suite("ArticleLeadImageRef")
struct ArticleLeadImageRefTests {
    private func makeArticle() -> Article {
        Article(title: "t", identifier: "id", url: "https://example.com")
    }

    @Test func leadImageRefTracksLeadingImageBlock() {
        let article = makeArticle()
        article.blocks = [
            .image(ref: "yana-img://lead", caption: []),
            .paragraph([InlineRun(text: "body")]),
        ]
        #expect(article.leadImageRef == "yana-img://lead")
    }

    @Test func leadImageRefEmptyWhenFirstBlockIsNotAnImage() {
        let article = makeArticle()
        article.blocks = [
            .paragraph([InlineRun(text: "body")]),
            .image(ref: "yana-img://inline", caption: []),
        ]
        #expect(article.leadImageRef.isEmpty)
    }

    @Test func leadImageRefClearsWhenBodyReplacedWithNonImageLead() {
        let article = makeArticle()
        article.blocks = [.image(ref: "yana-img://lead", caption: [])]
        #expect(article.leadImageRef == "yana-img://lead")
        article.blocks = [.paragraph([InlineRun(text: "no image now")])]
        #expect(article.leadImageRef.isEmpty)
    }

    @Test func leadImageRefEmptyForEmptyBody() {
        let article = makeArticle()
        article.blocks = []
        #expect(article.leadImageRef.isEmpty)
    }
}
