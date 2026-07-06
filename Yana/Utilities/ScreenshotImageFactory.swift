#if DEBUG
import UIKit

/// Deterministic, network-free lead images for the screenshot fixture (`-UITEST_SCREENSHOTS`).
/// Renders a diagonal two-color gradient with a bottom vignette so the images look like
/// editorial photos without shipping any binary assets.
enum ScreenshotImageFactory {
    /// Palette pairs (top-leading -> bottom-trailing), chosen for a warm, magazine-y feel.
    private static let palettes: [(UIColor, UIColor)] = [
        (UIColor(red: 0.15, green: 0.22, blue: 0.42, alpha: 1), UIColor(red: 0.36, green: 0.55, blue: 0.79, alpha: 1)),
        (UIColor(red: 0.42, green: 0.16, blue: 0.24, alpha: 1), UIColor(red: 0.86, green: 0.44, blue: 0.38, alpha: 1)),
        (UIColor(red: 0.13, green: 0.34, blue: 0.29, alpha: 1), UIColor(red: 0.40, green: 0.70, blue: 0.53, alpha: 1)),
        (UIColor(red: 0.28, green: 0.20, blue: 0.42, alpha: 1), UIColor(red: 0.60, green: 0.48, blue: 0.82, alpha: 1)),
        (UIColor(red: 0.40, green: 0.32, blue: 0.10, alpha: 1), UIColor(red: 0.85, green: 0.68, blue: 0.28, alpha: 1)),
    ]

    static func jpeg(index: Int) -> Data {
        let size = CGSize(width: 1200, height: 800)
        let (a, b) = palettes[abs(index) % palettes.count]
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [a.cgColor, b.cgColor] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient,
                                      start: .zero,
                                      end: CGPoint(x: size.width, y: size.height),
                                      options: [])
            }
            // Bottom vignette for text legibility.
            let vignette = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.35).cgColor] as CFArray
            if let vg = CGGradient(colorsSpace: space, colors: vignette, locations: [0, 1]) {
                cg.drawLinearGradient(vg,
                                      start: CGPoint(x: 0, y: size.height * 0.55),
                                      end: CGPoint(x: 0, y: size.height),
                                      options: [])
            }
        }
        // jpegData never returns nil for a renderer-produced image, but guard defensively.
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
#endif
