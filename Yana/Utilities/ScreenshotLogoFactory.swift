#if DEBUG
import UIKit

/// Generates fully-original, license-clean feed "logo" tiles for App Store screenshot
/// fixtures: a rounded-square tile in a given color with a bold white monogram centered
/// on it. Deterministic (same inputs always yield the same bytes) and network-free.
enum ScreenshotLogoFactory {
    private static let side: CGFloat = 180
    private static let cornerRadiusFraction: CGFloat = 0.22

    /// Renders a deterministic 180x180 rounded-square tile filled with `colorHex`
    /// (`#RRGGBB`), with `monogram` (1-2 characters) centered in bold white, auto-sized
    /// to fit. Returns PNG data, or empty data if rendering fails.
    static func png(monogram: String, colorHex: String) -> Data {
        let size = CGSize(width: side, height: side)
        let fillColor = Self.color(fromHex: colorHex) ?? .darkGray

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let cornerRadius = side * cornerRadiusFraction
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
            path.addClip()

            fillColor.setFill()
            ctx.fill(rect)

            let text = String(monogram.prefix(2))
            guard !text.isEmpty else { return }

            // Auto-size the bold monogram to fit within ~70% of the tile width, starting
            // from a large point size and shrinking until it fits.
            let maxWidth = side * 0.7
            var fontSize: CGFloat = side * 0.5
            var attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            var textSize = (text as NSString).size(withAttributes: attributes)
            while textSize.width > maxWidth, fontSize > 8 {
                fontSize -= 2
                attributes[.font] = UIFont.systemFont(ofSize: fontSize, weight: .bold)
                textSize = (text as NSString).size(withAttributes: attributes)
            }

            let origin = CGPoint(x: (side - textSize.width) / 2, y: (side - textSize.height) / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }

        return image.pngData() ?? Data()
    }

    /// Parses a `#RRGGBB` (or `RRGGBB`) hex string into a `UIColor`. Returns nil on malformed input.
    private static func color(fromHex hex: String) -> UIColor? {
        var stripped = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("#") { stripped.removeFirst() }
        guard stripped.count == 6, let value = UInt32(stripped, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255.0
        let green = CGFloat((value >> 8) & 0xFF) / 255.0
        let blue = CGFloat(value & 0xFF) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
#endif
