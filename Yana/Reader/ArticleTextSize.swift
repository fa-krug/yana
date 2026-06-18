import Foundation

/// User-selectable article body text size. CSS class names match the `.smallText … .xxlargeText`
/// rules in stylesheet.css. Ported/adapted from NetNewsWire's ArticleTextSize.
enum ArticleTextSize: Int, CaseIterable, Identifiable, Sendable {
    case small = 1
    case medium = 2
    case large = 3
    case xlarge = 4
    case xxlarge = 5

    var id: Int { rawValue }

    var cssClass: String {
        switch self {
        case .small: "smallText"
        case .medium: "mediumText"
        case .large: "largeText"
        case .xlarge: "xlargeText"
        case .xxlarge: "xxlargeText"
        }
    }

    /// Body font size in CSS pixels. These match the `.smallText … .xxlargeText` font sizes in
    /// stylesheet.css and are fed into the `[[font-size]]` macro so the selected size takes effect
    /// on iOS, where those discrete CSS classes live inside a macOS-only `@supports` block.
    var pointSize: Int {
        switch self {
        case .small: 14
        case .medium: 16
        case .large: 18
        case .xlarge: 20
        case .xxlarge: 22
        }
    }

    var displayName: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        case .xlarge: String(localized: "Extra Large")
        case .xxlarge: String(localized: "Extra Extra Large")
        }
    }
}
