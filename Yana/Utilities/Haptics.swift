#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Centralized, light wrapper around the platform's feedback generators so action sites stay terse.
///
/// The `Style`/`Notification` enums are Yana's own rather than UIKit's: re-exporting
/// `UIImpactFeedbackGenerator.FeedbackStyle` through the call signature made every caller — all of
/// them plain SwiftUI action closures — implicitly UIKit-dependent for the sake of a single case
/// name. They map one-to-one onto the UIKit cases on iOS.
///
/// macOS has one feedback pattern, not a taxonomy: `NSHapticFeedbackManager` performs `.generic`
/// (plus `.alignment`/`.levelChange`, neither of which fits an article action), and it does nothing
/// at all unless the user is on a Force Touch trackpad. So both entry points collapse to the same
/// call there and silently no-op on other hardware, which is the AppKit-intended behavior.
@MainActor
enum Haptics {
    enum Style {
        case light, medium, heavy, rigid, soft
    }

    enum Notification {
        case success, warning, error
    }

    static func impact(_ style: Style = .light) {
        #if os(macOS)
        perform()
        #else
        UIImpactFeedbackGenerator(style: style.uiStyle).impactOccurred()
        #endif
    }

    static func notify(_ type: Notification) {
        #if os(macOS)
        perform()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(type.uiType)
        #endif
    }

    #if os(macOS)
    private static func perform() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
    #endif
}

#if !os(macOS)
private extension Haptics.Style {
    var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: .light
        case .medium: .medium
        case .heavy: .heavy
        case .rigid: .rigid
        case .soft: .soft
        }
    }
}

private extension Haptics.Notification {
    var uiType: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
}
#endif
