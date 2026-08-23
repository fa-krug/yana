import Testing
import SwiftData
@testable import Yana

@MainActor
struct ScreenshotSeedTests {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
            #expect(feed.logoImageHash != nil, "feed \(feed.name) has no logoImageHash")
        }

        // Every article got a generated lead image + authored body, so blocks are never empty.
        for article in articles {
            #expect(!article.blocks.isEmpty, "article \(article.identifier) has no blocks")
        }

        // The AI summary the `01_Reader` shot shows is a block at the document's summary slot --
        // second, after the lead image -- the same shape the server delivers, so the captures
        // exercise the real render path rather than a fixture-only one.
        for article in articles {
            let blocks = article.blocks
            #expect(blocks.count >= 2, "article \(article.identifier) is too short to place a summary")
            guard case .summary = blocks[1] else {
                Issue.record("article \(article.identifier) has no summary block at the slot")
                continue
            }
        }

        // The anchor was parked on the hero article.
        let anchor = AppSettings().timelineAnchorIdentifier
        #expect(anchor == "screenshot://0/0")
        #expect(articles.contains { $0.identifier == anchor })
    }
}
