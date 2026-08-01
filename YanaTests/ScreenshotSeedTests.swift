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

    @Test func seedAuthorsOriginalLibraryWithGeneratedImagery() async throws {
        let context = try inMemoryContext()
        // Call the internal seeding routine directly, bypassing the launch-arg gate. This
        // exercises authoring the in-code feeds/articles and generating every logo/lead image
        // in-process (no bundled manifest, no network).
        await ScreenshotSeed.seed(into: context)

        let feeds = try context.fetch(FetchDescriptor<Feed>())
        #expect(feeds.count == 5)

        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 11)

        // Every feed got a generated logo.
        for feed in feeds {
            #expect(feed.logoHash != nil, "feed \(feed.name) has no logoHash")
        }

        // Every article got a generated lead image + authored body, so blocks are never empty.
        for article in articles {
            #expect(!article.blocks.isEmpty, "article \(article.identifier) has no blocks")
        }

        // The anchor was parked on the hero article.
        let anchor = AppSettings().timelineAnchorIdentifier
        #expect(anchor == "screenshot://0/0")
        #expect(articles.contains { $0.identifier == anchor })
    }
}
