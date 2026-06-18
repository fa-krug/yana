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
