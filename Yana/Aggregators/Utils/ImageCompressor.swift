import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Downscales + re-encodes images on-device (ImageIO), mirroring the server's Pillow step.
/// Header images are capped to ~1200px; output is JPEG (or PNG when transparency matters).
enum ImageCompressor {
    static func compress(_ data: Data, contentType: String?, isHeader: Bool) -> (data: Data, ext: String)? {
        guard data.count >= 100, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let maxDimension = isHeader ? 1200 : 2000
        let cgImage = downscale(image, maxDimension: maxDimension)

        let hasAlpha = cgImage.alphaInfo != .none && cgImage.alphaInfo != .noneSkipLast && cgImage.alphaInfo != .noneSkipFirst
        let useType: UTType = hasAlpha ? .png : .jpeg
        let ext = hasAlpha ? "png" : "jpg"

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, useType.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = useType == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, ext)
    }

    private static func downscale(_ image: CGImage, maxDimension: Int) -> CGImage {
        let w = image.width, h = image.height
        let longest = max(w, h)
        guard longest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(longest)
        let nw = Int(Double(w) * scale), nh = Int(Double(h) * scale)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }
}
