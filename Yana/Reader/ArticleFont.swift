import SwiftUI

/// User-selectable article body typeface. Each case maps to one of the built-in system font
/// designs (`Font.Design`) so no font assets need bundling. Applied to the reader via a
/// `.fontDesign(_:)` modifier; the monospaced code-block style pins its own design and is
/// therefore unaffected by this choice.
enum ArticleFont: Int, CaseIterable, Identifiable, Sendable {
    case system = 0
    case serif = 1
    case rounded = 2
    case monospaced = 3

    var id: Int { rawValue }

    var design: Font.Design {
        switch self {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .serif: String(localized: "Serif")
        case .rounded: String(localized: "Rounded")
        case .monospaced: String(localized: "Monospaced")
        }
    }
}
