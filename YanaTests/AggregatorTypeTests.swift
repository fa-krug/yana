import Testing
@testable import Yana

@Suite("AggregatorType")
struct AggregatorTypeTests {
    @Test func hasAllFifteenCases() {
        #expect(AggregatorType.allCases.count == 15)
    }

    @Test func customScriptIsURLBasedAndNeedsNoAPIKey() {
        #expect(AggregatorType.customScript.rawValue == "custom_script")
        #expect(AggregatorType.customScript.identifierKind == .url)
        #expect(AggregatorType.customScript.requiredAPIKey == AggregatorAPIKey.none)
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
    }
}
