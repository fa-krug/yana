import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSearch")
struct ArticleSearchTests {
    private func article(title: String = "", content: String = "", author: String = "", feedName: String = "") -> Article {
        let a = Article(title: title, identifier: UUID().uuidString, url: "u", content: content, author: author)
        if !feedName.isEmpty { a.feed = Feed(name: feedName, aggregatorType: .feedContent, identifier: "f") }
        return a
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(ArticleSearch.matches(article(title: "anything"), query: "   "))
    }

    @Test func matchesAcrossTitleContentAuthorFeedName() {
        #expect(ArticleSearch.matches(article(title: "Swift 6 ships"), query: "swift"))
        #expect(ArticleSearch.matches(article(content: "<p>Concurrency</p>"), query: "concurrency"))
        #expect(ArticleSearch.matches(article(author: "Jane Doe"), query: "jane"))
        #expect(ArticleSearch.matches(article(feedName: "Heise"), query: "heise"))
    }

    @Test func nonMatchIsExcluded() {
        #expect(!ArticleSearch.matches(article(title: "Kotlin"), query: "swift"))
    }

    @Test func filterReturnsOnlyMatches() {
        let articles = [article(title: "Swift"), article(title: "Rust"), article(author: "swifty")]
        #expect(ArticleSearch.filter(articles, query: "swift").count == 2)
    }
}
