import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Generates fully-original, license-clean feed "logo" tiles for App Store screenshot
/// fixtures: a rounded-square tile in a given color with a bold white monogram centered
/// on it. Deterministic (same inputs always yield the same bytes) and network-free. Also used to
/// generate demo-mode feed logos when onboarding's server step is skipped (see `ScreenshotSeed`).
enum ScreenshotLogoFactory {
    private static let side: CGFloat = 180
    private static let cornerRadiusFraction: CGFloat = 0.22

    /// Renders a deterministic 180x180 rounded-square tile filled with `colorHex`
    /// (`#RRGGBB`), with `monogram` (1-2 characters) centered in bold white, auto-sized
    /// to fit. Returns PNG data, or empty data if rendering fails.
    static func png(monogram: String, colorHex: String) -> Data {
        let size = CGSize(width: side, height: side)
        let fillColor = Self.color(fromHex: colorHex) ?? .darkGray

        return PlatformImageRenderer.pngData(size: size) { cgContext in
            let rect = CGRect(origin: .zero, size: size)
            let cornerRadius = side * cornerRadiusFraction
            // CoreGraphics rather than `UIBezierPath` (whose `NSBezierPath` twin spells the rounded-
            // rect initializer differently and has no `addClip()` on a path built this way).
            cgContext.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                                     cornerHeight: cornerRadius, transform: nil))
            cgContext.clip()

            cgContext.setFillColor(fillColor.cgColor)
            cgContext.fill(rect)

            let text = String(monogram.prefix(2))
            guard !text.isEmpty else { return }

            // Auto-size the bold monogram to fit within ~70% of the tile width, starting
            // from a large point size and shrinking until it fits.
            let maxWidth = side * 0.7
            var fontSize: CGFloat = side * 0.5
            var attributes: [NSAttributedString.Key: Any] = [
                .font: PlatformFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: PlatformColor.white
            ]
            var textSize = (text as NSString).size(withAttributes: attributes)
            while textSize.width > maxWidth, fontSize > 8 {
                fontSize -= 2
                attributes[.font] = PlatformFont.systemFont(ofSize: fontSize, weight: .bold)
                textSize = (text as NSString).size(withAttributes: attributes)
            }

            let origin = CGPoint(x: (side - textSize.width) / 2, y: (side - textSize.height) / 2)
            // `NSString.draw` takes no context argument on either platform — it draws into whatever
            // context is current, which `PlatformImageRenderer` guarantees it has pushed.
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    /// Parses a `#RRGGBB` (or `RRGGBB`) hex string into a color. Returns nil on malformed input.
    private static func color(fromHex hex: String) -> PlatformColor? {
        var stripped = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("#") { stripped.removeFirst() }
        guard stripped.count == 6, let value = UInt32(stripped, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255.0
        let green = CGFloat((value >> 8) & 0xFF) / 255.0
        let blue = CGFloat(value & 0xFF) / 255.0
        return PlatformColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
