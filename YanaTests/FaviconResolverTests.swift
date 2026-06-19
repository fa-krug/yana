import Foundation
import Testing
@testable import Yana

@Suite("FaviconResolver parsing")
struct FaviconResolverTests {
    private let base = URL(string: "https://example.com/blog/")!

    @Test func prefersAppleTouchIcon() {
        let html = """
        <html><head>
          <link rel="icon" sizes="32x32" href="/favicon-32.png">
          <link rel="apple-touch-icon" href="/touch.png">
        </head></html>
        """
        #expect(FaviconResolver.bestIconURL(fromHTML: html, baseURL: base) == "https://example.com/touch.png")
    }

    @Test func prefersLargestSizeAmongIcons() {
        let html = """
        <html><head>
          <link rel="icon" sizes="16x16" href="/small.png">
          <link rel="icon" sizes="180x180" href="/big.png">
        </head></html>
        """
        #expect(FaviconResolver.bestIconURL(fromHTML: html, baseURL: base) == "https://example.com/big.png")
    }

    @Test func resolvesRelativeHrefAgainstBase() {
        let html = #"<html><head><link rel="shortcut icon" href="icon.ico"></head></html>"#
        #expect(FaviconResolver.bestIconURL(fromHTML: html, baseURL: base) == "https://example.com/blog/icon.ico")
    }

    @Test func returnsNilWhenNoIconLink() {
        let html = "<html><head><title>No icons</title></head></html>"
        #expect(FaviconResolver.bestIconURL(fromHTML: html, baseURL: base) == nil)
    }

    @Test func networkUsesParsedIconWhenPresent() async {
        let html = #"<html><head><link rel="apple-touch-icon" href="/touch.png"></head></html>"#
        let icon = await FaviconResolver.uncachedBestIconURL(forSite: "https://example.com/") { _ in
            (Data(html.utf8), "text/html")
        }
        #expect(icon == "https://example.com/touch.png")
    }

    @Test func networkFallsBackToFaviconIco() async {
        let html = "<html><head><title>No icons</title></head></html>"
        let icon = await FaviconResolver.uncachedBestIconURL(forSite: "https://example.com/path/") { _ in
            (Data(html.utf8), "text/html")
        }
        #expect(icon == "https://example.com/favicon.ico")
    }

    @Test func networkReturnsNilWhenFetchThrows() async {
        struct Boom: Error {}
        let icon = await FaviconResolver.uncachedBestIconURL(forSite: "https://example.com/") { _ in throw Boom() }
        #expect(icon == nil)
    }
}
