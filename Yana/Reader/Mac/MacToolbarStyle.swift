import SwiftUI

/// Shared Mac-toolbar metrics. The joined capsule, segment spacing and menu chevron all come from
/// the system (a `ControlGroup` hosted directly by a `ToolbarItem` — see `MacRootView.toolbar`); the
/// one thing it gets visibly wrong is width — an icon-only button is sized to the symbol, which is
/// narrower than the button is tall.
enum MacToolbarMetrics {
    /// Horizontal breathing room added inside every toolbar button's label. Without it a lone
    /// button's background comes out as an upright oval — it reads as a "0" — and grouped segments
    /// sit cramped against each other. Padding to roughly square makes a single button a circle and
    /// gives each segment of a group room. Verified against captured Catalyst window screenshots.
    static let iconPadding: CGFloat = 6
}

extension View {
    /// Apply to the **label** of a Mac toolbar button so its background is padded to a round (or,
    /// in a group, comfortably wide) shape. Must sit on the label, not the `Button`: padding outside
    /// the button would push the item around instead of widening its background.
    ///
    /// No-op off Mac Catalyst — the iOS nav bar sizes its own items correctly.
    func macToolbarIcon() -> some View {
        #if targetEnvironment(macCatalyst)
        padding(.horizontal, MacToolbarMetrics.iconPadding)
        #else
        self
        #endif
    }
}
