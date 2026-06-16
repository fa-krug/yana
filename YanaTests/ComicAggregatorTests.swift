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
        #expect(!a.content.contains("Source:"))                         // source link lives in the toolbar now
    }

    final class StubDarkLegacy: DarkLegacyAggregator, @unchecked Sendable {
        let page: String
        init(page: String, store: ImageStore) {
            self.page = page
            super.init(config: FeedConfig(type: .darkLegacy, identifier: "", dailyLimit: 20,
                                          options: .darkLegacy(DarkLegacyOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { [ComicAggregatorTests().entry("https://darklegacycomics.com/172")] }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func darkLegacyResolvesRelativeImageURLs() async throws {
        let page = "<html><body><div id=\"gallery\"><img src=\"/images/172.png\" alt=\"DL\"></div></body></html>"
        let agg = StubDarkLegacy(page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))
        #expect(a.content.contains("DL"))
    }

    final class StubOglaf: OglafAggregator, @unchecked Sendable {
        let page: String
        init(page: String, store: ImageStore) {
            self.page = page
            super.init(config: FeedConfig(type: .oglaf, identifier: "", dailyLimit: 20,
                                          options: .oglaf(OglafOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { [ComicAggregatorTests().entry("https://www.oglaf.com/2025/")] }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func oglafShowsTitleJokeAsCaption() async throws {
        let page = "<html><body><div class=\"content\">"
            + "<img id=\"strip\" src=\"https://media.oglaf.com/comic/x.jpg\" alt=\"alt\" "
            + "title=\"the second joke\"></div></body></html>"
        let agg = StubOglaf(page: page, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))
        #expect(a.content.contains("the second joke"))
    }

    final class StubFailingExplosm: ExplosmAggregator, @unchecked Sendable {
        init(store: ImageStore) {
            super.init(config: FeedConfig(type: .explosm, identifier: "", dailyLimit: 20,
                                          options: .explosm(ExplosmOptions()), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { [ComicAggregatorTests().entry("https://explosm.net/comics/1")] }
        override func fetchArticleHTML(_ url: String) async throws -> String {
            throw AggregatorError.contentFetch("simulated network failure")
        }
    }

    @Test func failedComicFetchSkipsArticleWithoutAbortingRun() async throws {
        let agg = StubFailingExplosm(store: tempStore())
        let articles = try await agg.aggregate()
        #expect(articles.isEmpty)   // the failed comic is omitted; aggregate() does not throw
    }
}
