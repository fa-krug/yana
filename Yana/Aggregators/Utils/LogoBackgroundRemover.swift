import Foundation
import CoreGraphics

/// Makes the flat white background of a logo transparent.
///
/// Detects whether an image sits on a near-white background by sampling its border, then
/// clears only the white region that is *connected to the edge* via a flood fill — so white
/// that is enclosed by the subject (e.g. lettering inside a dark circle) is preserved. Returns
/// `nil` when no white background is detected, so callers keep the original bytes untouched.
enum LogoBackgroundRemover {
    /// A channel value at/above this counts as "white" (0...255).
    private static let whiteThreshold: UInt8 = 240
    /// Fraction of border pixels that must be near-white to treat the image as white-backed.
    private static let borderWhiteFraction = 0.85

    static func removingWhiteBackground(from cgImage: CGImage) -> CGImage? {
        let width = cgImage.width, height = cgImage.height
        guard width > 2, height > 2 else { return nil }

        // Decode into a known premultiplied-RGBA8 buffer we can read and mutate directly.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func isWhite(_ offset: Int) -> Bool {
            pixels[offset] >= whiteThreshold &&
            pixels[offset + 1] >= whiteThreshold &&
            pixels[offset + 2] >= whiteThreshold &&
            pixels[offset + 3] >= 250
        }

        // Detection: only proceed when most of the border is near-white.
        var borderTotal = 0, borderWhite = 0
        func sampleBorder(_ x: Int, _ y: Int) {
            borderTotal += 1
            if isWhite((y * width + x) * 4) { borderWhite += 1 }
        }
        for x in 0..<width { sampleBorder(x, 0); sampleBorder(x, height - 1) }
        for y in 1..<(height - 1) { sampleBorder(0, y); sampleBorder(width - 1, y) }
        guard borderTotal > 0, Double(borderWhite) / Double(borderTotal) >= borderWhiteFraction else { return nil }

        // Flood fill the edge-connected white region (4-connectivity), clearing it to transparent.
        var visited = [Bool](repeating: false, count: width * height)
        var stack = [Int]()
        func push(_ x: Int, _ y: Int) {
            let p = y * width + x
            if visited[p] { return }
            visited[p] = true
            if isWhite(p * 4) { stack.append(p) }
        }
        for x in 0..<width { push(x, 0); push(x, height - 1) }
        for y in 0..<height { push(0, y); push(width - 1, y) }

        while let p = stack.popLast() {
            let o = p * 4
            pixels[o] = 0; pixels[o + 1] = 0; pixels[o + 2] = 0; pixels[o + 3] = 0
            let x = p % width, y = p / width
            if x > 0 { push(x - 1, y) }
            if x < width - 1 { push(x + 1, y) }
            if y > 0 { push(x, y - 1) }
            if y < height - 1 { push(x, y + 1) }
        }

        return ctx.makeImage()
    }
}
