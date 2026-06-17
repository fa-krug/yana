import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("DomainImageOverrides")
@MainActor
struct DomainImageOverridesTests {

    // MARK: - Lookup tests

    @Test func noMatchReturnsNil() {
        #expect(DomainImageOverrides.overrideImageURL(for: "https://example.com/page") == nil)
    }

    @Test func emptyStringReturnsNil() {
        #expect(DomainImageOverrides.overrideImageURL(for: "") == nil)
    }

    @Test func exactPrefixMatchReturnsOverride() {
        let url = "https://en-americas-support.nintendo.com/app/answers/detail/a_id/123"
        let result = DomainImageOverrides.overrideImageURL(for: url)
        #expect(result == "https://upload.wikimedia.org/wikipedia/commons/0/0d/Nintendo.svg")
    }

    @Test func longestPrefixWins() {
        // Use two overlapping prefixes so the tie-breaking path is actually exercised.
        let localMap: [String: String] = [
            "https://example.com/": "https://img.example.com/root.png",
            "https://example.com/games/": "https://img.example.com/games.png",
        ]
        // Deep URL under /games/ — must match the longer prefix.
        let deepURL = "https://example.com/games/item/42"
        #expect(
            DomainImageOverrides.overrideImageURL(for: deepURL, in: localMap)
                == "https://img.example.com/games.png"
        )
        // Shallow URL not under /games/ — must match only the shorter prefix.
        let shallowURL = "https://example.com/news/article"
        #expect(
            DomainImageOverrides.overrideImageURL(for: shallowURL, in: localMap)
                == "https://img.example.com/root.png"
        )
    }

    @Test func partialPrefixDoesNotMatch() {
        // URL that contains the hostname but doesn't start with the full prefix.
        let url = "http://en-americas-support.nintendo.com/page"  // http not https
        #expect(DomainImageOverrides.overrideImageURL(for: url) == nil)
    }

    // MARK: - HeaderElementExtractor integration

    @Test func overrideURLProducesHeaderBeforeOtherStrategies() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ImageStore(directory: dir, fetch: { url in
            // Return a minimal PNG for any URL
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
            let data = renderer.image { ctx in UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }.pngData()!
            return (data, "image/png")
        })

        // Nintendo support URL — not a direct image URL, would normally produce nil.
        let articleURL = "https://en-americas-support.nintendo.com/app/answers/detail/a_id/123"
        let header = await HeaderElementExtractor.extract(
            articleURL: articleURL, title: "Nintendo Help", store: store, credentials: .init())

        #expect(header != nil)
        // The header image src uses the image scheme (cached override image).
        #expect(header?.html.contains("\(ReaderWeb.imageScheme)://") == true)
        // The dedup URL is the override image URL, not the article URL.
        #expect(header?.dedupURL == "https://upload.wikimedia.org/wikipedia/commons/0/0d/Nintendo.svg")
    }
}
