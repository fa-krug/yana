import Foundation
import Testing
@testable import Yana

@Suite("AggregatorOptions")
struct AggregatorOptionsTests {
    private func roundTrip(_ value: AggregatorOptions) throws -> AggregatorOptions {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AggregatorOptions.self, from: data)
    }

    @Test func websiteOptionsRoundTrip() throws {
        var opts = WebsiteOptions()
        opts.useFullContent = false
        opts.customContentSelector = "article.main"
        opts.ai.summarize = true
        let decoded = try roundTrip(.fullWebsite(opts))
        guard case .fullWebsite(let out) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(out.useFullContent == false)
        #expect(out.customContentSelector == "article.main")
        #expect(out.ai.summarize == true)
    }

    @Test func redditOptionsRoundTrip() throws {
        var opts = RedditOptions()
        opts.subredditSort = "top"
        opts.commentLimit = 25
        let decoded = try roundTrip(.reddit(opts))
        guard case .reddit(let out) = decoded else {
            Issue.record("wrong case"); return
        }
        #expect(out.subredditSort == "top")
        #expect(out.commentLimit == 25)
    }

    @Test func defaultsMatchExpectations() {
        #expect(WebsiteOptions().useFullContent == true)
        #expect(RedditOptions().subredditSort == "hot")
        #expect(PodcastOptions().includePlayer == true)
        #expect(AIOptions().translateLanguage == "English")
    }
}
