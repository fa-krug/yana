import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry — social/media")
struct AggregatorRegistrySocialTests {
    @Test func buildsRedditYouTubePodcast() {
        let reddit = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 20,
                                options: .reddit(RedditOptions()), collectedToday: 0)
        let youtube = FeedConfig(type: .youtube, identifier: "UCabc", dailyLimit: 20,
                                 options: .youtube(YouTubeOptions()), collectedToday: 0)
        let podcast = FeedConfig(type: .podcast, identifier: "https://p.com/feed", dailyLimit: 20,
                                 options: .podcast(PodcastOptions()), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: "k")
        #expect(AggregatorRegistry.shared.makeAggregator(reddit, credentials: creds) is RedditAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(youtube, credentials: creds) is YouTubeAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(podcast, credentials: creds) is PodcastAggregator)
    }

    /// Every AggregatorType now resolves to a concrete aggregator (no unregistered types remain).
    @Test func everyTypeResolvesToAnAggregator() {
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: "k")
        for type in AggregatorType.allCases {
            let cfg = FeedConfig(type: type, identifier: "x", dailyLimit: 20,
                                 options: type.defaultOptions, collectedToday: 0)
            #expect(AggregatorRegistry.shared.makeAggregator(cfg, credentials: creds) != nil,
                    "\(type.rawValue) should resolve to an aggregator")
        }
    }
}
