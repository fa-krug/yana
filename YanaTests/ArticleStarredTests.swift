import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Article.starred")
struct ArticleStarredTests {
    @Test func defaultsToFalseAndIsMutable() throws {
        let container = try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let article = Article(title: "Test", identifier: "id-1", url: "https://example.com")
        context.insert(article)
        #expect(article.starred == false)
        article.starred = true
        #expect(article.starred == true)
    }
}
