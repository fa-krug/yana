import Foundation
import Testing
@testable import Yana

@Suite("FeedDiscovery")
struct FeedDiscoveryTests {
    private let base = URL(string: "https://example.com/blog")!

    @Test func findsRSSAlternateLink() {
        let html = """
        <html><head>
          <link rel="alternate" type="application/rss+xml" href="https://example.com/feed.xml">
        </head><body></body></html>
        """
        let url = FeedDiscovery.feedURL(inHTML: html, baseURL: base)
        #expect(url?.absoluteString == "https://example.com/feed.xml")
    }

    @Test func prefersRSSOverAtom() {
        let html = """
        <html><head>
          <link rel="alternate" type="application/atom+xml" href="/atom.xml">
          <link rel="alternate" type="application/rss+xml" href="/rss.xml">
        </head></html>
        """
        let url = FeedDiscovery.feedURL(inHTML: html, baseURL: base)
        #expect(url?.absoluteString == "https://example.com/rss.xml")
    }

    @Test func fallsBackToAtomWhenNoRSS() {
        let html = #"<link rel="alternate" type="application/atom+xml" href="/atom.xml">"#
        let url = FeedDiscovery.feedURL(inHTML: html, baseURL: base)
        #expect(url?.absoluteString == "https://example.com/atom.xml")
    }

    @Test func resolvesRelativeHref() {
        let html = #"<link rel="alternate" type="application/rss+xml" href="feed/index.xml">"#
        let url = FeedDiscovery.feedURL(inHTML: html, baseURL: base)
        #expect(url?.absoluteString == "https://example.com/feed/index.xml")
    }

    @Test func returnsNilWhenNoFeedLink() {
        let html = "<html><head><title>No feed here</title></head><body>hi</body></html>"
        #expect(FeedDiscovery.feedURL(inHTML: html, baseURL: base) == nil)
    }

    @Test func discoverUsesInjectedFetch() async throws {
        let html = #"<link rel="alternate" type="application/rss+xml" href="https://example.com/f.xml">"#
        let url = try await FeedDiscovery.discoverFeedURL(from: base, fetchHTML: { _ in html })
        #expect(url?.absoluteString == "https://example.com/f.xml")
    }
}
