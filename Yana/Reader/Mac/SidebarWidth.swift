import CoreGraphics

/// The Mac sidebar column's width bounds and clamping. Extracted as a pure helper so the
/// persisted-width restore (`AppSettings.macSidebarWidth`) can be validated in isolation and the
/// `NavigationSplitView` column stays within the source-list-friendly range.
enum SidebarWidth {
    static let min: CGFloat = 300
    static let ideal: CGFloat = 360
    static let max: CGFloat = 480

    /// Clamp an observed/stored width into `[min, max]`.
    static func clamp(_ width: CGFloat) -> CGFloat {
        Swift.min(Swift.max(width, min), max)
    }
}
