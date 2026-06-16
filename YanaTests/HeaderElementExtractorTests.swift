import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("HeaderElementExtractor")
struct HeaderElementExtractorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300))
        let png = renderer.image { ctx in UIColor.green.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300)) }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    @Test func youTubeURLProducesEmbedHeader() async {
        let store = tempStore()
        let header = await HeaderElementExtractor.extract(
            articleURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "T", store: store, credentials: .init())
        #expect(header?.html.contains("youtube-embed-container") == true)
    }

    @Test func genericImageURLProducesCachedImageHeader() async {
        let store = tempStore()
        let header = await HeaderElementExtractor.extract(
            articleURL: "https://x.com/photo.jpg", title: "T", store: store, credentials: .init())
        #expect(header?.html.contains("\(ReaderWeb.imageScheme)://") == true)
        #expect(header?.dedupURL == "https://x.com/photo.jpg")
    }

    @Test func classifiesByPathExtension() {
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/a/photo.jpg") == true)
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/a/photo.PNG") == true)
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/article?ref=foo.jpg") == false)
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/article.png-gallery") == false)
        #expect(HeaderElementExtractor.looksLikeImage("https://x.com/article") == false)
    }
}
