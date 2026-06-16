import Foundation
import Testing
@testable import Yana

@Suite("Feed identifier choices")
struct FeedIdentifierChoicesTests {
    @Test func choicesForScraperTypes() {
        #expect(AggregatorType.heise.identifierChoices.count == 4)
        #expect(AggregatorType.merkur.identifierChoices.count == 18)
        #expect(AggregatorType.tagesschau.identifierChoices.count == 42)
        #expect(AggregatorType.caschysBlog.identifierChoices.count == 1)
        #expect(AggregatorType.meinMmo.identifierChoices.count == 1)
    }

    @Test func noChoicesForForcedOrGenericTypes() {
        #expect(AggregatorType.mactechnews.identifierChoices.isEmpty)   // forced feed
        #expect(AggregatorType.fullWebsite.identifierChoices.isEmpty)
        #expect(AggregatorType.feedContent.identifierChoices.isEmpty)
        #expect(AggregatorType.reddit.identifierChoices.isEmpty)
    }
}
