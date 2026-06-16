import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("RSSPipelineAggregator")
struct RSSPipelineAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50))
            .image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func config() -> FeedConfig {
        FeedConfig(type: .feedContent, identifier: "https://x.com/feed", dailyLimit: 20,
                   options: .feedContent(FeedContentOptions()), collectedToday: 0)
    }

    /// Subclass that injects canned entries instead of fetching.
    final class StubFeed: RSSPipelineAggregator, @unchecked Sendable {
        let entries: [FeedEntry]
        init(entries: [FeedEntry], config: FeedConfig, store: ImageStore) {
            self.entries = entries
            super.init(config: config, credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
    }

    @Test func mapsEntriesAndWrapsContent() async throws {
        let entry = FeedEntry(title: "Hello", link: "https://x.com/1", content: "<p>Body</p>",
                              summary: nil, entryDescription: nil, published: .now, author: "Al",
                              enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
        let agg = StubFeed(entries: [entry], config: config(), store: tempStore())
        let articles = try await agg.aggregate()
        let a = try #require(articles.first)
        #expect(a.title == "Hello")
        #expect(a.identifier == "https://x.com/1")
        #expect(a.content.contains("Body"))
        #expect(a.content.contains("article-content"))      // wrapped
        #expect(a.content.contains("Source:"))               // footer
    }

    @Test func emptyIdentifierFailsValidation() async {
        var cfg = config(); cfg.identifier = ""
        let agg = StubFeed(entries: [], config: cfg, store: tempStore())
        await #expect(throws: AggregatorError.self) { try await agg.aggregate() }
    }
}
