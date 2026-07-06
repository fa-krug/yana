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

    @Test func seedInsertsCuratedLibrary() async throws {
        let context = try inMemoryContext()
        // Call the internal seeding routine directly, bypassing the launch-arg gate.
        await ScreenshotSeed.seed(into: context)

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count >= 12)
        // Every article has a block body and a createdAt spread across recent time.
        #expect(articles.allSatisfy { !$0.blocks.isEmpty })
        // Multiple distinct feeds (aggregator variety).
        let feeds = try context.fetch(FetchDescriptor<Feed>())
        #expect(feeds.count >= 4)
        // An anchor was parked on one of the seeded articles.
        let anchor = AppSettings().timelineAnchorIdentifier
        #expect(anchor != nil)
        #expect(articles.contains { $0.identifier == anchor })
    }
}
