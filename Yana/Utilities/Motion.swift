import SwiftUI

/// Resolves animations/transitions against the Reduce Motion accessibility setting. When the user
/// has enabled Reduce Motion, animations collapse to `nil` (instant) and transitions to `.identity`,
/// so state changes apply without motion. Views read `@Environment(\.accessibilityReduceMotion)`
/// and pass it here.
enum Motion {
    static func resolve(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func resolve(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : transition
    }
}
