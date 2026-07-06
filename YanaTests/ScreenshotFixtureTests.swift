import Testing
import Foundation
@testable import Yana

struct ScreenshotFixtureTests {
    @Test func roundTripsRealBlockContent() throws {
        let blocks = BlockParser.blocks(fromHTML: "<p>Hello <strong>world</strong></p>")
        #expect(!blocks.isEmpty)

        let article = ScreenshotFixture.Article(
            title: "A Real Article",
            url: "https://example.com/a-real-article",
            author: "Jane Author",
            summary: "A short summary of the article.",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            blocks: blocks
        )
        let feed = ScreenshotFixture.Feed(
            name: "Example Feed",
            identifier: "https://example.com/feed.xml",
            tagName: "Tech",
            tagColorHex: "#2E77D0",
            logoHash: "abc123",
            articles: [article]
        )
        let fixture = ScreenshotFixture(
            feeds: [feed],
            images: [ScreenshotFixture.Image(hash: "abc123", ext: "png")],
            anchorFeedIndex: 0,
            anchorArticleIndex: 0
        )

        let data = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(ScreenshotFixture.self, from: data)

        #expect(decoded.feeds[0].name == "Example Feed")
        #expect(decoded.feeds[0].tagName == "Tech")
        #expect(decoded.feeds[0].logoHash == "abc123")
        #expect(decoded.feeds[0].articles[0].title == "A Real Article")
        #expect(decoded.feeds[0].articles[0].summary == "A short summary of the article.")
        #expect(decoded.feeds[0].articles[0].blocks == blocks)
        #expect(decoded.anchorFeedIndex == 0)
        #expect(decoded.anchorArticleIndex == 0)
    }
}
