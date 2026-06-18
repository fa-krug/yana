import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("RewriteImages")
struct RewriteImagesTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300))
        let png = renderer.image { ctx in UIColor.green.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300)) }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    // MARK: - rewriteImages tests

    /// Test 1: data: src with srcset → largest-w candidate wins, img is kept
    @Test func dataSrcWithSrcsetUsesLargestCandidate() async throws {
        let store = tempStore()
        let html = """
        <html><body>
        <img src="data:image/svg+xml,<svg/>" srcset="https://x.com/a-336.jpg 336w, https://x.com/a-1008.jpg 1008w">
        </body></html>
        """
        let doc = try HTMLUtils.parse(html)
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: "https://x.com/"))
        let imgs = try doc.select("img")
        #expect(imgs.count == 1)
        let src = try imgs.first()!.attr("src")
        #expect(src.hasPrefix("\(ReaderWeb.imageScheme)://"))
    }

    /// Test 2: srcset only, no src at all → resolved to yana-img://
    @Test func srcsetOnlyNoSrcResolvesToCachedRef() async throws {
        let store = tempStore()
        let html = """
        <html><body>
        <img srcset="https://x.com/only.jpg 800w">
        </body></html>
        """
        let doc = try HTMLUtils.parse(html)
        try await rewriteImages(in: doc, store: store, baseURL: nil)
        let imgs = try doc.select("img")
        #expect(imgs.count == 1)
        let src = try imgs.first()!.attr("src")
        #expect(src.hasPrefix("\(ReaderWeb.imageScheme)://"))
    }

    /// Test 3: Regression — real src with no srcset still resolves correctly
    @Test func realSrcNoSrcsetStillResolves() async throws {
        let store = tempStore()
        let html = """
        <html><body>
        <img src="https://x.com/real.png">
        </body></html>
        """
        let doc = try HTMLUtils.parse(html)
        try await rewriteImages(in: doc, store: store, baseURL: nil)
        let imgs = try doc.select("img")
        #expect(imgs.count == 1)
        let src = try imgs.first()!.attr("src")
        #expect(src.hasPrefix("\(ReaderWeb.imageScheme)://"))
    }

    /// Test 4: data: src with NO srcset → img is removed
    @Test func dataSrcWithoutSrcsetIsRemoved() async throws {
        let store = tempStore()
        let html = """
        <html><body>
        <img src="data:image/svg+xml,<svg/>">
        </body></html>
        """
        let doc = try HTMLUtils.parse(html)
        try await rewriteImages(in: doc, store: store, baseURL: nil)
        let imgs = try doc.select("img")
        #expect(imgs.count == 0)
    }

    // MARK: - largestSrcsetURL unit tests

    /// Largest w-descriptor wins
    @Test func largestSrcsetURLPicksLargestW() {
        let result = largestSrcsetURL("https://x.com/small.jpg 336w, https://x.com/large.jpg 1008w, https://x.com/med.jpg 672w")
        #expect(result == "https://x.com/large.jpg")
    }

    /// x-descriptor: 2x wins over 1x
    @Test func largestSrcsetURLPicksLargestX() {
        let result = largestSrcsetURL("https://x.com/1x.jpg 1x, https://x.com/2x.jpg 2x")
        #expect(result == "https://x.com/2x.jpg")
    }

    /// No descriptors → first candidate
    @Test func largestSrcsetURLReturnsFirstWhenNoDescriptors() {
        let result = largestSrcsetURL("https://x.com/first.jpg, https://x.com/second.jpg")
        #expect(result == "https://x.com/first.jpg")
    }

    /// Empty string → nil
    @Test func largestSrcsetURLReturnsNilForEmptyString() {
        let result = largestSrcsetURL("")
        #expect(result == nil)
    }

    /// data: candidate URLs are ignored
    @Test func largestSrcsetURLIgnoresDataURIs() {
        let result = largestSrcsetURL("data:image/svg+xml,<svg/> 1x, https://x.com/real.jpg 2x")
        #expect(result == "https://x.com/real.jpg")
    }
}
