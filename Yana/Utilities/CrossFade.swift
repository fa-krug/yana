import SwiftUI

/// Single source of truth for the loading→loaded fade used across every surface, so the
/// masking feels consistent. Keep it subtle and native — a plain opacity ease, no custom curve.
enum CrossFade {
    /// Fade duration in seconds.
    static let duration: TimeInterval = 0.2
    /// SwiftUI animation for `withAnimation` / `.animation(_:value:)`.
    static var animation: Animation { .easeInOut(duration: duration) }
    /// SwiftUI transition for content that swaps loading→loaded.
    static var transition: AnyTransition { .opacity }
}
