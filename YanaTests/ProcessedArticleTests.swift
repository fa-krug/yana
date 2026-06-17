import Testing
@testable import Yana

@MainActor
struct ProcessedArticleTests {
    @Test func processedArticleStoresFields() {
        let p = ProcessedArticle(title: "T", content: "<p>C</p>")
        #expect(p.title == "T")
        #expect(p.content == "<p>C</p>")
    }
}
