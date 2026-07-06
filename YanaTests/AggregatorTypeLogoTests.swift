import Testing
@testable import Yana

@Suite("AggregatorType.brandSiteURL")
struct AggregatorTypeLogoTests {
    @Test func fixedBrandTypesHaveSiteURLs() {
        #expect(AggregatorType.heise.brandSiteURL == "https://www.heise.de/")
        #expect(AggregatorType.merkur.brandSiteURL == "https://www.merkur.de/")
        #expect(AggregatorType.tagesschau.brandSiteURL == "https://www.tagesschau.de/")
        #expect(AggregatorType.explosm.brandSiteURL == "https://explosm.net/")
        #expect(AggregatorType.darkLegacy.brandSiteURL == "https://darklegacycomics.com/")
        #expect(AggregatorType.caschysBlog.brandSiteURL == "https://stadt-bremerhaven.de/")
        #expect(AggregatorType.mactechnews.brandSiteURL == "https://www.mactechnews.de/")
        #expect(AggregatorType.oglaf.brandSiteURL == "https://www.oglaf.com/")
        #expect(AggregatorType.meinMmo.brandSiteURL == "https://mein-mmo.de/")
        #expect(AggregatorType.theVerge.brandSiteURL == "https://www.theverge.com/")
    }

    @Test func nonBrandTypesHaveNoSiteURL() {
        for type in [AggregatorType.fullWebsite, .feedContent, .youtube, .reddit, .podcast] {
            #expect(type.brandSiteURL == nil)
        }
    }
}
