import Foundation
import Testing
@testable import Yana

@Suite("FeedURLResolver")
struct FeedURLResolverTests {
    // MARK: - normalized (missing scheme)

    @Test func prependsHTTPSWhenSchemeMissing() {
        #expect(FeedURLResolver.normalized("golem.de") == "https://golem.de")
        #expect(FeedURLResolver.normalized("www.golem.de/rss.php") == "https://www.golem.de/rss.php")
    }

    @Test func keepsExistingHTTPScheme() {
        #expect(FeedURLResolver.normalized("http://example.com") == "http://example.com")
        #expect(FeedURLResolver.normalized("https://example.com/feed") == "https://example.com/feed")
    }

    @Test func rewritesFeedScheme() {
        #expect(FeedURLResolver.normalized("feed://example.com/rss.xml") == "https://example.com/rss.xml")
    }

    @Test func trimsWhitespaceAndPassesEmptyThrough() {
        #expect(FeedURLResolver.normalized("  golem.de  ") == "https://golem.de")
        #expect(FeedURLResolver.normalized("   ") == "")
    }

    // MARK: - resolvedFeedURL

    @Test func keepsURLThatIsAlreadyAFeed() async {
        let rss = Data("""
        <?xml version="1.0"?><rss version="2.0"><channel><title>T</title>
        <item><title>A</title><link>https://e.com/a</link></item></channel></rss>
        """.utf8)
        let resolved = await FeedURLResolver.resolvedFeedURL("e.com/feed.xml", fetch: { _ in rss })
        #expect(resolved == "https://e.com/feed.xml")
    }

    @Test func discoversFeedFromHomepage() async {
        let html = Data("""
        <html><head>
        <link rel="alternate" type="application/rss+xml" href="https://golem.de/rss.php?feed=RSS2.0">
        </head><body>hi</body></html>
        """.utf8)
        let resolved = await FeedURLResolver.resolvedFeedURL("golem.de", fetch: { _ in html })
        #expect(resolved == "https://golem.de/rss.php?feed=RSS2.0")
    }

    @Test func fallsBackToNormalizedWhenNoFeedDiscoverable() async {
        let html = Data("<html><head><title>no feed</title></head><body>hi</body></html>".utf8)
        let resolved = await FeedURLResolver.resolvedFeedURL("example.com", fetch: { _ in html })
        #expect(resolved == "https://example.com")
    }

    @Test func fallsBackToNormalizedOnFetchFailure() async {
        struct Boom: Error {}
        let resolved = await FeedURLResolver.resolvedFeedURL("example.com", fetch: { _ in throw Boom() })
        #expect(resolved == "https://example.com")
    }
}
