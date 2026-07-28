import Foundation
import SwiftData
@testable import Yana

/// Builds an on-disk library of realistic size and shape, for tests that need the cost of a real
/// full-library fetch to be measurable (an in-memory store is too fast to distinguish a
/// main-thread stall from a background one).
enum LibraryFixture {

    /// A seeded store plus the directory holding it; the caller removes the directory when done.
    struct Handle {
        let container: ModelContainer
        let directory: URL
    }

    /// `cloudKit: true` builds the store the shipping app uses (`.automatic`), which is what turns
    /// on persistent history tracking and therefore `.NSPersistentStoreRemoteChange`. Only tests
    /// that care about mirroring behaviour need it; it initialises fine without an iCloud account.
    static func make(articleCount: Int, feedCount: Int = 12, tagCount: Int = 8,
                     cloudKit: Bool = false) throws -> Handle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yana-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: Feed.self, Tag.self, Article.self, StoredImage.self,
            configurations: ModelConfiguration(url: dir.appendingPathComponent("test.store"),
                                               cloudKitDatabase: cloudKit ? .automatic : .none)
        )
        let context = ModelContext(container)

        let tags = (0..<tagCount).map { Tag(name: "Tag\($0)", sortOrder: $0) }
        tags.forEach { context.insert($0) }
        let feeds: [Feed] = (0..<feedCount).map { i in
            let feed = Feed(name: "Feed \(i)", aggregatorType: .feedContent,
                            identifier: "https://example.com/feed\(i).xml")
            feed.tags = [tags[i % tagCount], tags[(i + 1) % tagCount]]
            context.insert(feed)
            return feed
        }

        // ~8 KB of body per article, so the store is the size a real library reaches.
        let body = String(repeating: "Lorem ipsum dolor sit amet. ", count: 300)
        for i in 0..<articleCount {
            let feed = feeds[i % feeds.count]
            let article = Article(
                title: "Article number \(i) with a fairly typical headline length",
                identifier: "https://example.com/feed\(i % feeds.count)/post-\(i)",
                url: "https://example.com/post-\(i)",
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60),
                author: "Author \(i % 40)"
            )
            article.createdAt = article.date
            article.feed = feed
            article.tags = feed.tags
            article.syncFeedIdentifier = feed.identifier
            article.syncAggregatorType = feed.aggregatorType
            article.plainText = body
            article.blockData = Data(body.utf8)
            context.insert(article)
        }
        try context.save()
        return Handle(container: container, directory: dir)
    }

    /// Insert `count` articles from a background context and save — the shape of one CloudKit
    /// import batch landing in the store.
    static func importBatch(into container: ModelContainer, feedID: PersistentIdentifier,
                            offset: Int, count: Int) async {
        await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let feed = context.model(for: feedID) as? Feed
            let body = String(repeating: "Lorem ipsum dolor sit amet. ", count: 300)
            for i in offset..<(offset + count) {
                let article = Article(
                    title: "Synced article \(i)",
                    identifier: "https://example.com/synced/post-\(i)",
                    url: "https://example.com/synced/post-\(i)",
                    date: Date(timeIntervalSince1970: 1_600_000_000 + Double(i) * 60)
                )
                article.createdAt = article.date
                article.feed = feed
                article.tags = feed?.tags
                article.plainText = body
                article.blockData = Data(body.utf8)
                context.insert(article)
            }
            try? context.save()
        }.value
    }
}
