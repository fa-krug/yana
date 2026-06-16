import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("ImageCompressor")
struct ImageCompressorTests {
    private func pngData(_ side: Int) -> Data {
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!
    }

    @Test func compressesAndReturnsExtension() {
        let result = ImageCompressor.compress(pngData(2000), contentType: "image/png", isHeader: true)
        let out = try? #require(result)
        #expect(out != nil)
        #expect(["jpg", "png", "webp"].contains(out!.ext))
        #expect(out!.data.count > 0)
    }

    @Test func rejectsTinyImages() {
        // < min size guard (a few bytes is not a valid image)
        #expect(ImageCompressor.compress(Data([0x00, 0x01]), contentType: "image/png", isHeader: false) == nil)
    }
}
