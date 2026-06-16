import Foundation
import UIKit
import SwiftSoup
import Testing
@testable import Yana

@Suite("ImageStore")
struct ImageStoreTests {
    private func pngData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300))
        return renderer.image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300)) }.pngData()!
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func storeDownloadsCompressesAndReturnsHash() async {
        let data = pngData()
        let store = ImageStore(directory: tempDir(), fetch: { _ in (data, "image/png") })
        let hash = await store.store(remoteURL: URL(string: "https://x.com/a.png")!, isHeader: false)
        let h = try? #require(hash)
        #expect(h != nil)
        #expect(FileManager.default.fileExists(atPath: await store.fileURL(forHash: h!).path))
    }

    @Test func rewriteImagesReplacesSrcWithScheme() async throws {
        let data = pngData()
        let store = ImageStore(directory: tempDir(), fetch: { _ in (data, "image/png") })
        let doc = try SwiftSoup.parse("<img src=\"https://x.com/a.png\"><p>hi</p>")
        try await rewriteImages(in: doc, store: store, baseURL: nil)
        let html = try doc.body()!.html()
        #expect(html.contains("\(ReaderWeb.imageScheme)://"))
        #expect(!html.contains("https://x.com/a.png"))
    }
}
