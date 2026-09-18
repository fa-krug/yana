import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Draws a bitmap off a `CGContext` and encodes it, standing in for `UIGraphicsImageRenderer` —
/// which has no AppKit equivalent at all. The screenshot fixtures (`ScreenshotImageFactory`,
/// `ScreenshotLogoFactory`) are the only users; both want bytes out, never a live image, so the
/// surface is just "draw into this context, hand me JPEG/PNG data".
///
/// Two things the callers rely on and that the macOS branch has to arrange by hand:
///
/// - **The context is flipped** (origin top-left, y increasing downward), matching UIKit. AppKit's
///   bitmap contexts are bottom-left by default, which would mirror every gradient and put the
///   monogram off the tile. The CTM flip and the `flipped: true` `NSGraphicsContext` are both
///   required: the first moves the geometry, the second tells AppKit's own drawing (`NSString.draw`,
///   `NSBezierPath`) that it has already been moved.
/// - **The AppKit context is pushed as current**, so `NSString.draw(at:withAttributes:)` and
///   `NSColor.setFill()` — which take no context argument — find one. `UIGraphicsImageRenderer` does
///   the same for UIKit implicitly, which is why the iOS branch simply delegates to it rather than
///   reimplementing over a raw `CGContext`: keeping that path byte-identical to what ships today is
///   worth more than symmetry between the two branches.
enum PlatformImageRenderer {
    /// Backing-store scale. UIKit picks the main screen's scale, so a 1200x800 fixture is really
    /// 2400x1600 on a 2x device; macOS is pinned to 2 to land in the same ballpark rather than
    /// querying a screen that may not exist during a headless test run.
    #if os(macOS)
    private static let scale = 2
    #endif

    /// Renders `draw` into a `size`-point bitmap and encodes it as JPEG.
    /// Returns empty data if the platform could not produce a bitmap (out of memory, degenerate size).
    static func jpegData(size: CGSize, compressionQuality: CGFloat, draw: (CGContext) -> Void) -> Data {
        #if os(macOS)
        guard let rep = bitmap(size: size, draw: draw) else { return Data() }
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: compressionQuality]) ?? Data()
        #else
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in draw(context.cgContext) }
        return image.jpegData(compressionQuality: compressionQuality) ?? Data()
        #endif
    }

    /// Renders `draw` into a `size`-point bitmap and encodes it as PNG.
    /// Returns empty data if the platform could not produce a bitmap.
    static func pngData(size: CGSize, draw: (CGContext) -> Void) -> Data {
        #if os(macOS)
        guard let rep = bitmap(size: size, draw: draw) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
        #else
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in draw(context.cgContext) }
        return image.pngData() ?? Data()
        #endif
    }

    #if os(macOS)
    private static func bitmap(size: CGSize, draw: (CGContext) -> Void) -> NSBitmapImageRep? {
        let pixelsWide = Int((size.width * CGFloat(scale)).rounded())
        let pixelsHigh = Int((size.height * CGFloat(scale)).rounded())
        guard pixelsWide > 0, pixelsHigh > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // Report the rep in points, so the encoded image carries the intended logical size.
        rep.size = size
        guard let cgContext = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }

        cgContext.saveGState()
        cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // Flip to UIKit's top-left origin (see the type comment).
        cgContext.translateBy(x: 0, y: size.height)
        cgContext.scaleBy(x: 1, y: -1)

        let appKitContext = NSGraphicsContext(cgContext: cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = appKitContext
        draw(cgContext)
        NSGraphicsContext.restoreGraphicsState()
        cgContext.restoreGState()
        return rep
    }
    #endif
}
