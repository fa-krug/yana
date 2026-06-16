import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("MerkurAggregator")
struct MerkurAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry() -> FeedEntry {
        FeedEntry(title: "Merkur story", link: "https://www.merkur.de/a-1", content: "<p>s</p>",
                  summary: "<p>s</p>", entryDescription: nil, published: .now, author: "",
                  enclosures: [], itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubMerkur: MerkurAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, options: MerkurOptions, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .merkur, identifier: "https://www.merkur.de/rssfeed.rdf",
                                          dailyLimit: 20, options: .merkur(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func extractsIdjsStoryAndRemovesEmptyWhenEnabled() async throws {
        let page = """
        <html><body><div class="idjs-Story"><p>Keep this</p><p></p>\
        <figcaption>caption</figcaption></div></body></html>
        """
        let agg = StubMerkur(entries: [entry()], page: page, options: MerkurOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Keep this"))
        #expect(!a.content.contains("caption"))                 // figcaption removed
        #expect(a.content.contains("<p></p>") == false)         // empty paragraph removed
    }

    @Test func keepsEmptyWhenRemoveEmptyDisabled() async throws {
        let page = "<div class=\"idjs-Story\"><p>Body</p><p></p></div>"
        let agg = StubMerkur(entries: [entry()], page: page,
                             options: { var o = MerkurOptions(); o.removeEmptyElements = false; return o }(),
                             store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("<p></p>"))
    }

    @Test func identifierChoicesHas18RegionalFeeds() {
        #expect(MerkurAggregator.identifierChoices.count == 18)
        #expect(MerkurAggregator.identifierChoices.first?.value == "https://www.merkur.de/rssfeed.rdf")
    }
}
