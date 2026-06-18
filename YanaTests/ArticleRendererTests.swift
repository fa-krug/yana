import Testing
import Foundation
import SwiftData
@testable import Yana

@MainActor
struct ArticleRendererTests {
    private func makeArticle() -> Article {
        let feed = Feed(name: "Example Feed", aggregatorType: .feedContent, identifier: "https://example.com")
        feed.logoHash = "abc123"
        let article = Article(
            title: "Hello & Welcome",
            identifier: "https://example.com/post/1",
            url: "https://example.com/post/1",
            content: "<p>Body text here.</p>",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            author: "Jane Doe"
        )
        article.feed = feed
        return article
    }

    @Test func rendersTitleBodyBylineAndAvatar() {
        let r = ArticleRenderer.articleHTML(article: makeArticle(), theme: .defaultTheme, textSize: .medium)
        #expect(r.html.contains("Hello &amp; Welcome"))
        #expect(r.html.contains("Body text here."))
        #expect(r.html.contains("Jane Doe"))
        #expect(r.html.contains("Example Feed"))
        #expect(r.html.contains("yana-img://abc123"))
        #expect(r.html.contains("mediumText"))
        #expect(r.title == "Hello &amp; Welcome")
        #expect(r.baseURL == "https://example.com")
    }

    @Test func emptyAuthorAndLogoRenderCleanly() {
        let article = makeArticle()
        article.author = ""
        article.feed?.logoHash = nil
        let r = ArticleRenderer.articleHTML(article: article, theme: .defaultTheme, textSize: .large)
        #expect(!r.html.contains("yana-img://"))
        #expect(r.html.contains("largeText"))
    }

    @Test func fullPageEmbedsStyleAndBody() {
        let html = ArticleRenderer.fullPageHTML(article: makeArticle(), theme: .defaultTheme, textSize: .medium)
        #expect(html.contains("<style>"))
        #expect(html.contains("Body text here."))
        #expect(!html.contains("<script")) // JS intentionally dropped
    }
}
