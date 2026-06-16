import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ArticleListFiltering")
struct ArticleListFilteringTests {
    private func article(title: String, tagName: String?) -> Article {
        let a = Article(title: title, identifier: UUID().uuidString, url: "u")
        if let tagName { a.tags = [Tag(name: tagName)] }
        return a
    }

    @Test func searchThenTagFilterCompose() {
        let articles = [
            article(title: "Swift news", tagName: "Tech"),
            article(title: "Swift cooking", tagName: "Food"),
            article(title: "Rust news", tagName: "Tech"),
        ]
        let searched = ArticleSearch.filter(articles, query: "swift") // -> 2 articles
        let filtered = TagFilter.apply(to: searched, disabledTagNames: ["Food"], includeUntagged: true)
        #expect(filtered.count == 1)
        #expect(filtered.first?.title == "Swift news")
    }

    @Test func untaggedExcludedWhenFlagOff() {
        let articles = [article(title: "Swift", tagName: nil)]
        let searched = ArticleSearch.filter(articles, query: "swift")
        #expect(TagFilter.apply(to: searched, disabledTagNames: [], includeUntagged: false).isEmpty)
    }
}
