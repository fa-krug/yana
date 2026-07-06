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

    // MARK: - Backward-compatible decoding (data written by older builds)

    /// Regression for the TestFlight crash: a `MeinMmoOptions` persisted before
    /// `includeComments`/`maxComments` existed must decode (filling in defaults)
    /// rather than trapping on the missing keys.
    @Test func meinMmoDecodesLegacyDataMissingNewKeys() throws {
        let legacy = Data(#"{"combinePages": false}"#.utf8)
        let opts = try JSONDecoder().decode(MeinMmoOptions.self, from: legacy)
        #expect(opts.combinePages == false)        // preserved from old data
        #expect(opts.includeComments == true)      // filled from default
        #expect(opts.maxComments == 5)             // filled from default
        #expect(opts.ai == AIOptions())            // filled from default
    }

    /// The real crash path goes through the `AggregatorOptions` enum, mirroring how
    /// SwiftData decodes `Feed.options`. Decode a legacy `meinMmo` payload missing the
    /// new keys and assert it fills defaults instead of trapping.
    @Test func aggregatorOptionsDecodesLegacyMeinMmo() throws {
        // Encoded shape of the synthesized enum Codable: { "meinMmo": { "_0": {…} } }
        let legacy = Data(#"{"meinMmo": {"_0": {"combinePages": true}}}"#.utf8)
        let decoded = try JSONDecoder().decode(AggregatorOptions.self, from: legacy)
        guard case .meinMmo(let out) = decoded else { Issue.record("wrong case"); return }
        #expect(out.includeComments == true)
        #expect(out.maxComments == 5)
    }

    /// Decoding tolerates entirely empty objects (every key absent) for each struct.
    @Test func optionsStructsDecodeFromEmptyObject() throws {
        let empty = Data("{}".utf8)
        _ = try JSONDecoder().decode(AIOptions.self, from: empty)
        _ = try JSONDecoder().decode(WebsiteOptions.self, from: empty)
        _ = try JSONDecoder().decode(FeedContentOptions.self, from: empty)
        _ = try JSONDecoder().decode(RedditOptions.self, from: empty)
        _ = try JSONDecoder().decode(YouTubeOptions.self, from: empty)
        _ = try JSONDecoder().decode(PodcastOptions.self, from: empty)
        _ = try JSONDecoder().decode(HeiseOptions.self, from: empty)
        _ = try JSONDecoder().decode(MerkurOptions.self, from: empty)
        _ = try JSONDecoder().decode(TagesschauOptions.self, from: empty)
        _ = try JSONDecoder().decode(ExplosmOptions.self, from: empty)
        _ = try JSONDecoder().decode(DarkLegacyOptions.self, from: empty)
        _ = try JSONDecoder().decode(CaschysBlogOptions.self, from: empty)
        let mac = try JSONDecoder().decode(MactechnewsOptions.self, from: empty)
        #expect(mac.maxComments == 5)
        _ = try JSONDecoder().decode(OglafOptions.self, from: empty)
        let mmo = try JSONDecoder().decode(MeinMmoOptions.self, from: empty)
        #expect(mmo == MeinMmoOptions())
        _ = try JSONDecoder().decode(TheVergeOptions.self, from: empty)
        _ = try JSONDecoder().decode(ArsTechnicaOptions.self, from: empty)
    }
}
