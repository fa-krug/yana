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

    @Test func redditHasMinAgeHours() {
        #expect(RedditOptions().minAgeHours == 48)
    }

    @Test func oglafHasConvertToBase64() throws {
        var opts = OglafOptions()
        opts.convertToBase64 = false
        let decoded = try roundTrip(.oglaf(opts))
        guard case .oglaf(let out) = decoded else { Issue.record("wrong case"); return }
        #expect(out.convertToBase64 == false)
        #expect(out.showAltText == true)
    }

    @Test func heiseRoundTrip() throws {
        var opts = HeiseOptions()
        opts.maxComments = 9
        let decoded = try roundTrip(.heise(opts))
        guard case .heise(let out) = decoded else { Issue.record("wrong case"); return }
        #expect(out.maxComments == 9)
        #expect(out.includeComments == true)
    }

    @Test func defaultOptionsMatchType() {
        if case .heise = AggregatorType.heise.defaultOptions {} else { Issue.record("heise default") }
        if case .tagesschau = AggregatorType.tagesschau.defaultOptions {} else { Issue.record("tagesschau default") }
        if case .meinMmo = AggregatorType.meinMmo.defaultOptions {} else { Issue.record("meinMmo default") }
    }
}
