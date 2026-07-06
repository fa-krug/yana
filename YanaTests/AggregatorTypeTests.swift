import Testing
@testable import Yana

@Suite("AggregatorType")
struct AggregatorTypeTests {
    @Test func hasFifteenCases() {
        #expect(AggregatorType.allCases.count == 15)
    }

    @Test func rawValuesMatchYanaServer() {
        #expect(AggregatorType.fullWebsite.rawValue == "full_website")
        #expect(AggregatorType.feedContent.rawValue == "feed_content")
        #expect(AggregatorType.reddit.rawValue == "reddit")
        #expect(AggregatorType.youtube.rawValue == "youtube")
    }

    @Test func identifierKindVariesByType() {
        #expect(AggregatorType.reddit.identifierKind == .subreddit)
        #expect(AggregatorType.youtube.identifierKind == .youtubeChannel)
        #expect(AggregatorType.feedContent.identifierKind == .url)
        #expect(AggregatorType.oglaf.identifierKind == .none)
    }

    @Test func requiredAPIKeyVariesByType() {
        #expect(AggregatorType.reddit.requiredAPIKey == .reddit)
        #expect(AggregatorType.youtube.requiredAPIKey == .youtube)
        #expect(AggregatorType.feedContent.requiredAPIKey == AggregatorAPIKey.none)
    }

    @Test func displayNameIsHumanReadable() {
        #expect(AggregatorType.feedContent.displayName == "Feed Content (RSS/Atom)")
        #expect(AggregatorType.fullWebsite.displayName == "Full Website")
        #expect(AggregatorType.theVerge.displayName == "The Verge")
        #expect(AggregatorType.theVerge.rawValue == "the_verge")
    }
}
