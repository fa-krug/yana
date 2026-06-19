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
        #expect(!out!.data.isEmpty)
    }

    @Test func rejectsTinyImages() {
        // < min size guard (a few bytes is not a valid image)
        #expect(ImageCompressor.compress(Data([0x00, 0x01]), contentType: "image/png", isHeader: false) == nil)
    }

    /// A black disc on an opaque white square, 1pt == 1px.
    private func blackCircleOnWhite(_ side: Int) -> Data {
        let format = UIGraphicsImageRendererFormat.preferred(); format.scale = 1
        let s = CGFloat(side)
        let image = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            UIColor.black.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: s * 0.15, y: s * 0.15, width: s * 0.7, height: s * 0.7))
        }
        return image.pngData()!
    }

    private func alpha(_ data: Data, x: Int, y: Int) -> UInt8 {
        let image = UIImage(data: data)!.cgImage!
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf[(y * w + x) * 4 + 3]
    }

    @Test func removesWhiteBackgroundWhenRequested() throws {
        let out = try #require(ImageCompressor.compress(blackCircleOnWhite(200), contentType: "image/png",
                                                        isHeader: false, removeWhiteBackground: true))
        #expect(out.ext == "png")              // alpha introduced -> PNG, not JPEG
        #expect(alpha(out.data, x: 2, y: 2) == 0)        // corner now transparent
        #expect(alpha(out.data, x: 100, y: 100) == 255)  // subject preserved
    }

    @Test func keepsWhiteBackgroundWhenNotRequested() throws {
        let out = try #require(ImageCompressor.compress(blackCircleOnWhite(200), contentType: "image/png", isHeader: false))
        #expect(alpha(out.data, x: 2, y: 2) == 255)   // corner background untouched (opaque)
    }
}
