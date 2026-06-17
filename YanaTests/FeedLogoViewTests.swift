import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("FeedLogo image loading")
struct FeedLogoViewTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    @Test func loadsStoredImageByHash() async {
        let store = tempStore()
        let hash = await store.store(remoteURL: URL(string: "https://e.com/logo.png")!, isHeader: false)
        let image = await FeedLogo.image(forHash: hash, in: store)
        #expect(image != nil)
    }

    @Test func returnsNilForNilHash() async {
        let image = await FeedLogo.image(forHash: nil, in: tempStore())
        #expect(image == nil)
    }
}
