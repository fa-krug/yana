import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("ComicAggregator")
struct ComicAggregatorTests {
    func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    func entry(_ link: String) -> FeedEntry {
        FeedEntry(title: "Comic", link: link, content: "", summary: "", entryDescription: "",
                  published: .now, author: "", enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubExplosm: ExplosmAggregator, @unchecked Sendable {
        let page: String
        init(page: String, store: ImageStore) {
            self.page = page
            super.init(config: FeedConfig(type: .explosm, identifier: "", dailyLimit: 20,
                                          options: .explosm(ExplosmOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { [ComicAggregatorTests().entry("https://explosm.net/comics/1")] }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func explosmExtractsComicImageAndAltText() async throws {
        let page = """
        <html><body><div id="comic">
          <img src="https://static.explosm.net/2025/12/12/strip.png" alt="The joke">
        </div></body></html>
        """
        let agg = StubExplosm(page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))     // image localized
        #expect(!a.content.contains("static.explosm.net"))             // no remote URL
        #expect(a.content.contains("The joke"))                         // alt caption shown
        #expect(a.content.contains("Source:"))                          // footer
    }
}
