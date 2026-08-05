import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("FeedLogo image loading")
struct FeedLogoViewTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ImageStore(directory: dir)
    }

    /// Any client works here: the hash is already on disk, so `fetchIfNeeded` takes its
    /// cache-hit path and never touches the network.
    private func unusedClient() -> YanaAPIClient {
        YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t")
    }

    @Test func loadsStoredImageByHash() async {
        let store = tempStore()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in }.pngData()!
        let hash = await store.storeData(png, ext: "png")
        let image = await FeedLogo.image(forHash: hash, client: unusedClient(), in: store)
        #expect(image != nil)
    }

    @Test func returnsNilForNilHash() async {
        let image = await FeedLogo.image(forHash: nil, client: unusedClient(), in: tempStore())
        #expect(image == nil)
    }
}
