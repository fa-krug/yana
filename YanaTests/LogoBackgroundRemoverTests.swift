import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("LogoBackgroundRemover")
struct LogoBackgroundRemoverTests {
    /// A filled black circle centered on a white square.
    private func blackCircleOnWhite(_ side: Int) -> CGImage {
        render(side) { ctx, s in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            UIColor.black.setFill()
            let inset = s * 0.15
            ctx.cgContext.fillEllipse(in: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset))
        }
    }

    /// A black ring (donut) on white: a black disc with a white disc punched in its centre,
    /// so the centre white is fully enclosed by black and never touches the border.
    private func blackRingOnWhite(_ side: Int) -> CGImage {
        render(side) { ctx, s in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            UIColor.black.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: s * 0.15, y: s * 0.15, width: s * 0.7, height: s * 0.7))
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: s * 0.40, y: s * 0.40, width: s * 0.2, height: s * 0.2))
        }
    }

    /// A fully red square — no white background.
    private func solidRed(_ side: Int) -> CGImage {
        render(side) { ctx, s in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        }
    }

    private func render(_ side: Int, _ draw: (UIGraphicsImageRendererContext, CGFloat) -> Void) -> CGImage {
        let s = CGFloat(side)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1   // 1 point == 1 pixel, so test coordinates map directly
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: format)
        return renderer.image { ctx in draw(ctx, s) }.cgImage!
    }

    /// Reads a single pixel as premultiplied RGBA bytes.
    private func rgba(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return (buf[i], buf[i + 1], buf[i + 2], buf[i + 3])
    }

    @Test func makesWhiteBackgroundTransparentAndKeepsSubjectOpaque() throws {
        let out = try #require(LogoBackgroundRemover.removingWhiteBackground(from: blackCircleOnWhite(100)))
        #expect(rgba(out, 1, 1).a == 0)        // corner background -> transparent
        #expect(rgba(out, 50, 50).a == 255)    // black circle centre -> opaque
    }

    @Test func keepsInteriorWhiteThatIsEnclosedBySubject() throws {
        let out = try #require(LogoBackgroundRemover.removingWhiteBackground(from: blackRingOnWhite(100)))
        #expect(rgba(out, 1, 1).a == 0)        // outer white background -> transparent
        #expect(rgba(out, 50, 50).a == 255)    // enclosed white centre -> stays opaque
    }

    @Test func leavesImagesWithoutWhiteBackgroundUnchanged() {
        #expect(LogoBackgroundRemover.removingWhiteBackground(from: solidRed(100)) == nil)
    }
}
