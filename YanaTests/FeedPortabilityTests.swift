import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("FeedPortability")
struct FeedPortabilityTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func exportThenImportRoundTripsTypeOptionsAndTags() throws {
        let context = try makeContext()
        let tech = Yana.Tag(name: "Tech")
        context.insert(tech)
        var opts = HeiseOptions(); opts.maxComments = 9
        let feed = Feed(name: "Heise", aggregatorType: .heise, identifier: "https://heise.de/rss", dailyLimit: 15)
        feed.options = .heise(opts)
        feed.tags = [tech]
        context.insert(feed)

        let xml = FeedPortability.exportOPML(context: context)

        let fresh = try makeContext()
        let result = FeedPortability.importOPML(xml, context: fresh)
        #expect(result.imported == 1)

        let feeds = try fresh.fetch(FetchDescriptor<Feed>())
        let restored = try #require(feeds.first)
        #expect(restored.type == .heise)
        #expect(restored.dailyLimit == 15)
        #expect(restored.tags.map(\.name) == ["Tech"])
        if case let .heise(o) = restored.options { #expect(o.maxComments == 9) } else { Issue.record("wrong options case") }
    }

    @Test func importForeignOpmlCreatesFeedContentFeed() throws {
        let context = try makeContext()
        let xml = """
        <opml version="2.0"><body>
          <outline text="Blog" type="rss" xmlUrl="https://example.com/feed.xml" />
        </body></opml>
        """
        let result = FeedPortability.importOPML(xml, context: context)
        #expect(result.imported == 1)
        let feed = try #require(try context.fetch(FetchDescriptor<Feed>()).first)
        #expect(feed.type == .feedContent)
        #expect(feed.identifier == "https://example.com/feed.xml")
        #expect(feed.name == "Blog")
    }

    @Test func importSkipsDuplicateByIdentifierAndType() throws {
        let context = try makeContext()
        let existing = Feed(name: "Blog", aggregatorType: .feedContent, identifier: "https://example.com/feed.xml")
        context.insert(existing)
        let xml = """
        <opml version="2.0"><body>
          <outline text="Blog" type="rss" xmlUrl="https://example.com/feed.xml" yana:aggregatorType="feed_content" />
        </body></opml>
        """
        let result = FeedPortability.importOPML(xml, context: context)
        #expect(result.imported == 0)
        #expect(result.skipped == 1)
        #expect(try context.fetch(FetchDescriptor<Feed>()).count == 1)
    }

    @Test func importReusesExistingTagByName() throws {
        let context = try makeContext()
        let tech = Yana.Tag(name: "Tech")
        context.insert(tech)
        let xml = """
        <opml version="2.0"><body>
          <outline text="Heise" type="rss" xmlUrl="https://heise.de/rss" yana:aggregatorType="heise" yana:tags="Tech" />
        </body></opml>
        """
        _ = FeedPortability.importOPML(xml, context: context)
        let tags = try context.fetch(FetchDescriptor<Yana.Tag>())
        #expect(tags.filter { $0.name == "Tech" }.count == 1)
    }
}
