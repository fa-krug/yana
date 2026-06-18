import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("TagesschauAggregator")
struct TagesschauAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private func entry(_ title: String, link: String = "https://www.tagesschau.de/inland/story-1.html") -> FeedEntry {
        FeedEntry(title: title, link: link, content: "<p>s</p>", summary: "<p>s</p>",
                  entryDescription: nil, published: .now, author: "", enclosures: [],
                  itunesDuration: nil, itunesImage: nil, mediaThumbnails: [])
    }

    final class StubTS: TagesschauAggregator, @unchecked Sendable {
        let entries: [FeedEntry]; let page: String
        init(entries: [FeedEntry], page: String, options: TagesschauOptions, store: ImageStore) {
            self.entries = entries; self.page = page
            super.init(config: FeedConfig(type: .tagesschau,
                                          identifier: "https://www.tagesschau.de/infoservices/alle-meldungen-100~rss2.xml",
                                          dailyLimit: 20, options: .tagesschau(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
        override func fetchArticleHTML(_ url: String) async throws -> String { page }
    }

    @Test func extractsOnlyTextabsatzAndTrennerSkippingTeaser() async throws {
        let page = """
        <html><body>
        <p class="textabsatz">Real paragraph</p>
        <h2 class="trenner">Section heading</h2>
        <div class="teaser"><p class="textabsatz">Teaser noise</p></div>
        <p class="other">Ignored</p>
        </body></html>
        """
        let agg = StubTS(entries: [entry("Politik aktuell")], page: page, options: TagesschauOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("Real paragraph"))
        #expect(a.content.contains("Section heading"))
        #expect(!a.content.contains("Teaser noise"))         // teaser ancestor skipped
        #expect(!a.content.contains("Ignored"))               // not textabsatz
    }

    @Test func buildsVideoMediaHeaderFromMediaPlayer() async throws {
        // data-v JSON uses &quot; entities, like the real page.
        let json = "{&quot;mc&quot;:{&quot;streams&quot;:[{&quot;media&quot;:[{&quot;url&quot;:"
            + "&quot;https://t.de/v.mp4&quot;,&quot;mimeType&quot;:&quot;video/mp4&quot;}]}]}}"
        let page = """
        <html><body>
        <div data-v-type="MediaPlayer" class="mediaplayer teaser-top" data-v="\(json)"></div>
        <p class="textabsatz">Story text</p>
        </body></html>
        """
        let agg = StubTS(entries: [entry("Mit Video")], page: page, options: TagesschauOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("<video"))
        #expect(a.content.contains("https://t.de/v.mp4"))
        #expect(a.content.contains("Story text"))
    }

    @Test func usesDOMPosterWhenMediaPlayerJSONLacksImage() async throws {
        // Real Tagesschau video pages carry no poster in the MediaPlayer JSON; the preview
        // image lives in a sibling <picture> under the shared article-head__media parent.
        let json = "{&quot;mc&quot;:{&quot;streams&quot;:[{&quot;media&quot;:[{&quot;url&quot;:"
            + "&quot;https://t.de/v.mp4&quot;,&quot;mimeType&quot;:&quot;video/mp4&quot;}]}]}}"
        let page = """
        <html><body>
        <div class="article-head__media">
          <div class="ts-picture__poster-wrapper"><picture class="ts-picture ts-picture--teaser-top">
            <img class="ts-image" src="https://images.tagesschau.de/poster.jpg"></picture></div>
          <div data-v-type="MediaPlayer" class="mediaplayer teaser-top" data-v="\(json)"></div>
        </div>
        <p class="textabsatz">Story text</p>
        </body></html>
        """
        let agg = StubTS(entries: [entry("Mit Video")], page: page, options: TagesschauOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("<video"))
        #expect(a.content.contains("poster=\"https://images.tagesschau.de/poster.jpg\""))
    }

    @Test func skipsLivestreamAndPodcastTitlesAndVideoURLs() async throws {
        let agg = StubTS(entries: [
            entry("Livestream: Pressekonferenz"),
            entry("11KM-Podcast: Thema"),
            entry("Bericht", link: "https://www.tagesschau.de/multimedia/video/video-99.html"),
            entry("Keeper"),
        ], page: "<p class=\"textabsatz\">x</p>", options: TagesschauOptions(), store: tempStore())
        let titles = try await agg.aggregate().map(\.title)
        #expect(titles == ["Keeper"])
    }

    @Test func identifierChoicesMatchServerList() {
        #expect(TagesschauAggregator.identifierChoices.count == 42)
    }
}
