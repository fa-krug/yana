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

    @Test func storeDownloadsCompressesAndReturnsHash() async throws {
        let data = pngData()
        let store = ImageStore(directory: tempDir(), fetch: { _ in (data, "image/png") })
        let hash = await store.store(remoteURL: URL(string: "https://x.com/a.png")!, isHeader: false)
        let h = try #require(hash)
        #expect(FileManager.default.fileExists(atPath: await store.fileURL(forHash: h).path))
    }

    @Test func fileURLResolvesAcrossLaunches() async {
        let dir = tempDir()
        let data = pngData()
        let store1 = ImageStore(directory: dir, fetch: { _ in (data, "image/png") })
        let hash = await store1.store(remoteURL: URL(string: "https://x.com/a.png")!, isHeader: false)
        let h = hash ?? ""
        #expect(!h.isEmpty)

        // Simulate a fresh launch: a new store over the same dir has an empty extensions map.
        let store2 = ImageStore(directory: dir, fetch: { _ in (data, "image/png") })
        let resolved = await store2.fileURL(forHash: h)
        #expect(FileManager.default.fileExists(atPath: resolved.path))   // must find the existing file on disk
    }

    @Test func storeRemovesWhiteLogoBackgroundWhenRequested() async throws {
        let format = UIGraphicsImageRendererFormat.preferred(); format.scale = 1
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.black.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 30, y: 30, width: 140, height: 140))
        }.pngData()!

        let store = ImageStore(directory: tempDir(), fetch: { _ in (logo, "image/png") })
        let hash = try #require(await store.store(remoteURL: URL(string: "https://x.com/logo.png")!,
                                                  isHeader: false, removeWhiteBackground: true))
        let cached = UIImage(data: try Data(contentsOf: await store.fileURL(forHash: hash)))!.cgImage!
        var buf = [UInt8](repeating: 0, count: cached.width * cached.height * 4)
        let ctx = CGContext(data: &buf, width: cached.width, height: cached.height, bitsPerComponent: 8,
                            bytesPerRow: cached.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cached, in: CGRect(x: 0, y: 0, width: cached.width, height: cached.height))
        let cornerAlphaIndex: Int = (2 * cached.width + 2) * 4 + 3
        #expect(buf[cornerAlphaIndex] == 0)   // corner background transparent in the cached file
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
