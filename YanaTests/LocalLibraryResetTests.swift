import Foundation
import Testing
import SwiftData
@testable import Yana

@MainActor
struct LocalLibraryResetTests {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func wipeDeletesArticlesFeedsAndTagsAndClearsTheAnchor() throws {
        let context = try inMemoryContext()
        let feed = Feed(name: "Demo Feed", aggregator: "feedContent", identifier: "demo://feed")
        context.insert(feed)
        let tag = Yana.Tag(name: "Demo", colorHex: "#2E77D0")
        context.insert(tag)
        let article = Article(
            title: "Demo Article", identifier: "demo://article/0",
            url: "https://example.com", date: .now, author: "Someone"
        )
        article.feed = feed
        article.tags = [tag]
        context.insert(article)
        try context.save()

        AppSettings().timelineAnchorIdentifier = "demo://article/0"
        AppSettings().timelineAnchorServerID = 42
        AppSettings().syncCursor = "some-cursor"

        LocalLibraryReset.wipe(context: context)

        #expect(try context.fetch(FetchDescriptor<Article>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Feed>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Yana.Tag>()).isEmpty)
        #expect(AppSettings().timelineAnchorIdentifier == nil)
        #expect(AppSettings().timelineAnchorServerID == nil)
        #expect(AppSettings().syncCursor == nil)
    }
}
