import Testing
import SwiftData
@testable import Yana

@MainActor
struct ScreenshotSeedTests {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func noOpWithoutLaunchArgument() async throws {
        // The test process does not pass -UITEST_SCREENSHOTS, so seeding must not run.
        let context = try inMemoryContext()
        await ScreenshotSeed.seedIfRequested(into: context)
        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.isEmpty)
    }

    @Test func seedReplaysBundledFixture() async throws {
        let context = try inMemoryContext()
        // Call the internal seeding routine directly, bypassing the launch-arg gate. The test
        // host bundle includes the committed ScreenshotFixture snapshot (manifest.json + images),
        // so this genuinely exercises loading it — it would fail if the manifest were absent or
        // undecodable.
        await ScreenshotSeed.seed(into: context)

        let feeds = try context.fetch(FetchDescriptor<Feed>())
        #expect(feeds.count >= 4)

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count >= 8)

        // Every feed contributed at least one article.
        for feed in feeds {
            #expect(!feed.articles.isEmpty, "feed \(feed.name) has no articles")
        }

        // An anchor was parked on one of the seeded articles. Not every article has a non-empty
        // body (YouTube/Reddit articles legitimately have empty blocks), so we don't assert that.
        let anchor = AppSettings().timelineAnchorIdentifier
        #expect(anchor != nil)
        #expect(articles.contains { $0.identifier == anchor })
    }
}
