#if DEBUG
import UIKit

/// Generates fully-original, license-clean lead images for App Store screenshot fixtures.
/// Deterministic (same `index` always yields the same bytes) so the fixture is reproducible
/// and offline — no network fetch, no third-party imagery.
enum ScreenshotImageFactory {
    private static let size = CGSize(width: 1200, height: 800)

    /// Warm, magazine-y gradient pairs (top-left color, bottom-right color).
    private static let palettes: [(top: UIColor, bottom: UIColor)] = [
        (UIColor(red: 0.98, green: 0.55, blue: 0.36, alpha: 1), UIColor(red: 0.62, green: 0.16, blue: 0.24, alpha: 1)),
        (UIColor(red: 0.29, green: 0.36, blue: 0.66, alpha: 1), UIColor(red: 0.09, green: 0.11, blue: 0.28, alpha: 1)),
        (UIColor(red: 0.98, green: 0.78, blue: 0.32, alpha: 1), UIColor(red: 0.82, green: 0.35, blue: 0.14, alpha: 1)),
        (UIColor(red: 0.31, green: 0.62, blue: 0.55, alpha: 1), UIColor(red: 0.08, green: 0.27, blue: 0.28, alpha: 1)),
        (UIColor(red: 0.72, green: 0.32, blue: 0.58, alpha: 1), UIColor(red: 0.30, green: 0.11, blue: 0.36, alpha: 1))
    ]

    /// Renders a deterministic, tasteful abstract lead image (1200x800) for the given index:
    /// a diagonal gradient chosen from a warm palette, a subtle geometric motif, and a soft
    /// bottom vignette for text legibility. Returns JPEG data, or empty data if rendering fails.
    static func jpeg(index: Int) -> Data {
        let safeIndex = index == .min ? 0 : abs(index)
        let paletteIndex = safeIndex % palettes.count
        let palette = palettes[paletteIndex]

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cgContext = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // Diagonal multi-stop gradient between the two palette colors.
            let colors = [palette.top.cgColor, palette.bottom.cgColor] as CFArray
            let locations: [CGFloat] = [0.0, 1.0]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                cgContext.saveGState()
                cgContext.addRect(rect)
                cgContext.clip()
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
                cgContext.restoreGState()
            }

            // Subtle geometric motif: two large translucent circles, position/size varied by index.
            cgContext.saveGState()
            cgContext.setBlendMode(.plusLighter)
            let motif = safeIndex % 3
            let circle1Center: CGPoint
            let circle1Radius: CGFloat
            let circle2Center: CGPoint
            let circle2Radius: CGFloat
            switch motif {
            case 0:
                circle1Center = CGPoint(x: size.width * 0.85, y: size.height * 0.15)
                circle1Radius = size.width * 0.35
                circle2Center = CGPoint(x: size.width * 0.1, y: size.height * 0.9)
                circle2Radius = size.width * 0.22
            case 1:
                circle1Center = CGPoint(x: size.width * 0.15, y: size.height * 0.2)
                circle1Radius = size.width * 0.3
                circle2Center = CGPoint(x: size.width * 0.9, y: size.height * 0.75)
                circle2Radius = size.width * 0.28
            default:
                circle1Center = CGPoint(x: size.width * 0.5, y: size.height * 0.1)
                circle1Radius = size.width * 0.4
                circle2Center = CGPoint(x: size.width * 0.8, y: size.height * 0.95)
                circle2Radius = size.width * 0.18
            }

            cgContext.setFillColor(UIColor.white.withAlphaComponent(0.10).cgColor)
            cgContext.addEllipse(in: CGRect(x: circle1Center.x - circle1Radius, y: circle1Center.y - circle1Radius,
                                             width: circle1Radius * 2, height: circle1Radius * 2))
            cgContext.fillPath()

            cgContext.setFillColor(UIColor.white.withAlphaComponent(0.08).cgColor)
            cgContext.addEllipse(in: CGRect(x: circle2Center.x - circle2Radius, y: circle2Center.y - circle2Radius,
                                             width: circle2Radius * 2, height: circle2Radius * 2))
            cgContext.fillPath()
            cgContext.restoreGState()

            // Soft bottom vignette for text legibility.
            let vignetteColors = [
                UIColor.black.withAlphaComponent(0).cgColor,
                UIColor.black.withAlphaComponent(0.55).cgColor
            ] as CFArray
            if let vignette = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: vignetteColors, locations: [0.0, 1.0]) {
                cgContext.saveGState()
                cgContext.addRect(rect)
                cgContext.clip()
                cgContext.drawLinearGradient(
                    vignette,
                    start: CGPoint(x: 0, y: size.height * 0.55),
                    end: CGPoint(x: 0, y: size.height),
                    options: []
                )
                cgContext.restoreGState()
            }
        }

        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
#endif
