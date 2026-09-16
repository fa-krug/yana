import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform aliases for the UIKit/AppKit types Yana uses as plain *data* — an image it decodes
/// and hands to SwiftUI, a color it bakes into an `NSAttributedString`, a font descriptor it derives
/// traits from. In every one of those places the two frameworks agree on the API and only disagree
/// on the type name, so a typealias is the whole of the port.
///
/// Where the APIs genuinely differ (`NSImage` has no `animatedImage(with:duration:)`, `NSTextView`
/// has no `isScrollEnabled`) this file deliberately offers nothing: those call sites need a real
/// decision, and hiding them behind a shim that silently does something else on one platform is how
/// a port ends up with two behaviors and one test. The semantic helpers below cover only the cases
/// where an identical intent has two different spellings.
#if os(macOS)
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformFontDescriptor = NSFontDescriptor
typealias PlatformView = NSView
typealias PlatformViewController = NSViewController
typealias PlatformHostingController<Content: View> = NSHostingController<Content>
#else
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformFontDescriptor = UIFontDescriptor
typealias PlatformView = UIView
typealias PlatformViewController = UIViewController
typealias PlatformHostingController<Content: View> = UIHostingController<Content>
#endif

// MARK: - Semantic colors

/// The four system colors the reader bakes into attributed text and view backgrounds. AppKit spells
/// all four differently (`labelColor`, not `label`) and has no `systemBackground` at all — the Mac's
/// equivalent surface color is `windowBackgroundColor`. Prefixed `yana…` rather than shadowing the
/// UIKit names so a reader can tell at a glance that a color came through the shim.
extension PlatformColor {
    static var yanaLabel: PlatformColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }

    static var yanaSecondaryLabel: PlatformColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    static var yanaSeparator: PlatformColor {
        #if os(macOS)
        .separatorColor
        #else
        .separator
        #endif
    }

    static var yanaWindowBackground: PlatformColor {
        #if os(macOS)
        .windowBackgroundColor
        #else
        .systemBackground
        #endif
    }
}

// MARK: - Symbolic font traits

/// Bold/italic as symbolic traits. UIKit prefixes both with `trait`, AppKit does not — and since
/// these are `OptionSet` members rather than a protocol requirement, no amount of typealiasing makes
/// the two spellings line up. `ReaderAttributedText.appendRuns` inserts them into a descriptor's
/// existing trait set, so static members (rather than a `boldItalic(_:_:)` factory) are what the one
/// real call site actually wants.
extension PlatformFontDescriptor.SymbolicTraits {
    static var yanaBold: PlatformFontDescriptor.SymbolicTraits {
        #if os(macOS)
        .bold
        #else
        .traitBold
        #endif
    }

    static var yanaItalic: PlatformFontDescriptor.SymbolicTraits {
        #if os(macOS)
        .italic
        #else
        .traitItalic
        #endif
    }
}

// MARK: - Dynamic Type

extension PlatformFont {
    /// The reader's base body point size scaled by the user's system text-size setting.
    ///
    /// **There is no `NSFontMetrics`.** Dynamic Type is an iOS concept: macOS has no per-app text
    /// size ramp to scale against, and its accessibility text sizing happens below the app in
    /// AppKit's own controls. So the macOS branch returns the value unscaled rather than inventing a
    /// multiplier — the reader's own `ArticleTextSize` picker is the Mac's text-size control.
    static func scaledBodyValue(for value: CGFloat) -> CGFloat {
        #if os(macOS)
        value
        #else
        UIFontMetrics(forTextStyle: .body).scaledValue(for: value)
        #endif
    }
}

// MARK: - SwiftUI bridging

extension Image {
    /// `Image(uiImage:)` / `Image(nsImage:)` behind one name, for the views that display a
    /// `PlatformImage` decoded by `ReaderImageCache`.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// `UIImage(cgImage:)` has no zero-argument `NSImage` twin — AppKit needs an explicit point size,
    /// and passing `.zero` makes `NSImage` adopt the bitmap's own pixel dimensions, which is what the
    /// UIKit initializer does implicitly at scale 1.
    static func fromCGImage(_ cgImage: CGImage) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: cgImage, size: .zero)
        #else
        UIImage(cgImage: cgImage)
        #endif
    }
}
