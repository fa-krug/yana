import Foundation
import Testing
@testable import Yana

@Suite("FeedLogoResolver")
struct FeedLogoResolverTests {
    private struct FakeAggregator: Aggregator {
        var logo: String?
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { [] }
        func logoImageURL() async -> String? { logo }
    }

    private func config(_ type: AggregatorType, _ identifier: String) -> FeedConfig {
        FeedConfig(type: type, identifier: identifier, dailyLimit: 10,
                   options: type.defaultOptions, collectedToday: 0)
    }

    @Test func usesAPIImageWhenAggregatorProvidesOne() async {
        var faviconCalled = false
        let result = await FeedLogoResolver.logoImageURL(
            for: config(.reddit, "swift"),
            aggregator: FakeAggregator(logo: "https://api/icon.png"),
            faviconResolver: { _ in faviconCalled = true; return "https://should/not.png" })
        #expect(result == "https://api/icon.png")
        #expect(faviconCalled == false)
    }

    @Test func usesBrandSiteFaviconForFixedBrands() async {
        var capturedSite: String?
        let result = await FeedLogoResolver.logoImageURL(
            for: config(.heise, ""),
            aggregator: FakeAggregator(logo: nil),
            faviconResolver: { site in capturedSite = site; return "https://www.heise.de/favicon.ico" })
        #expect(capturedSite == "https://www.heise.de/")
        #expect(result == "https://www.heise.de/favicon.ico")
    }

    @Test func usesIdentifierOriginForURLBasedFeeds() async {
        var capturedSite: String?
        let result = await FeedLogoResolver.logoImageURL(
            for: config(.feedContent, "https://blog.example.com/feed.xml"),
            aggregator: FakeAggregator(logo: nil),
            faviconResolver: { site in capturedSite = site; return "\(site)favicon.ico" })
        #expect(capturedSite == "https://blog.example.com/")
        #expect(result == "https://blog.example.com/favicon.ico")
    }

    @Test func siteOriginExtractsSchemeAndHost() {
        #expect(FeedLogoResolver.siteOrigin(of: "https://a.b.com/x/y?q=1") == "https://a.b.com/")
        #expect(FeedLogoResolver.siteOrigin(of: "not-a-url") == nil)
    }
}
