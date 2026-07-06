#if DEBUG
import Foundation

/// A frozen snapshot of real feed content, collected once from live feeds by
/// `ScreenshotFixtureCollector` and replayed offline by `ScreenshotSeed` to produce App Store
/// screenshots. Image bytes are NOT inlined here — each `Image` names a file bundled alongside
/// the manifest as `images/<hash>.<ext>`, re-inserted into `ImageStore` at seed time.
struct ScreenshotFixture: Codable, Sendable {
    struct Image: Codable, Sendable {
        var hash: String
        var ext: String
    }
    struct Article: Codable, Sendable {
        var title: String
        var url: String
        var author: String
        var summary: String
        var date: Date
        var blocks: [Block]
    }
    struct Feed: Codable, Sendable {
        var name: String
        var identifier: String
        var tagName: String
        var tagColorHex: String
        var logoHash: String?
        var articles: [Article]
    }
    var feeds: [Feed]
    var images: [Image]
    var anchorFeedIndex: Int
    var anchorArticleIndex: Int
}
#endif
