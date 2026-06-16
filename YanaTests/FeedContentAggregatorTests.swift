import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("FeedContentAggregator")
struct FeedContentAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    final class StubFeedContent: FeedContentAggregator, @unchecked Sendable {
        let entries: [FeedEntry]
        init(entries: [FeedEntry], store: ImageStore) {
            self.entries = entries
            super.init(config: FeedConfig(type: .feedContent, identifier: "u", dailyLimit: 20,
                                          options: .feedContent(FeedContentOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
    }

    @Test func usesRssContentAndDownloadsImages() async throws {
        let entry = FeedEntry(title: "T", link: "https://x.com/1",
                              content: "<p>Body</p><img src=\"https://x.com/p.png\">",
                              summary: nil, entryDescription: nil, published: .now, author: "",
                              enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
        let agg = StubFeedContent(entries: [entry], store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Body"))
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))   // image localized
        #expect(!a.content.contains("https://x.com/p.png"))           // no remote URL
    }
}
