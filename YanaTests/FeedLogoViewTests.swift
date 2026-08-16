import Foundation
import UIKit
import Testing
@testable import Yana

/// Feed logos load through `ReaderImageCache` now (audit P8), so these pin that same path with a
/// `yana-img://` ref rather than the deleted `FeedLogo` enum's direct file read. `ReaderImageCache`
/// always reads through `ImageStore.shared` (it has no injectable store), so the hit case stores
/// into that shared on-disk cache directly, exactly like a real sync would.
@Suite("Feed logo image loading")
struct FeedLogoViewTests {
    @Test func loadsStoredImageByHash() async {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in }.pngData()!
        let hash = await ImageStore.shared.storeData(png, ext: "png")
        let image = await ReaderImageCache.shared.image(for: "yana-img://\(hash)")
        #expect(image != nil)
    }

    @Test func returnsNilForMissingHash() async {
        let image = await ReaderImageCache.shared.image(for: "yana-img://\(UUID().uuidString)")
        #expect(image == nil)
    }
}
