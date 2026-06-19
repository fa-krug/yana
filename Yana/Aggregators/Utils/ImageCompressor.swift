import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Downscales + re-encodes images on-device (ImageIO), mirroring the server's Pillow step.
/// Header images are capped to ~1200px; output is JPEG (or PNG when transparency matters).
enum ImageCompressor {
    /// When `removeWhiteBackground` is true (used for feed logos), a flat white background
    /// connected to the image edge is made transparent before encoding — see `LogoBackgroundRemover`.
    static func compress(_ data: Data, contentType: String?, isHeader: Bool,
                         removeWhiteBackground: Bool = false) -> (data: Data, ext: String)? {
        guard data.count >= 100, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let maxDimension = isHeader ? 1200 : 2000
        // Decode-and-downscale in one step: avoids fully decoding huge source images into memory.
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard var cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // Logos: knock out a flat white backdrop so the icon sits transparently on any theme.
        if removeWhiteBackground, let stripped = LogoBackgroundRemover.removingWhiteBackground(from: cgImage) {
            cgImage = stripped
        }

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
}
