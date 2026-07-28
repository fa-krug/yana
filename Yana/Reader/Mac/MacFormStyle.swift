import SwiftUI

/// Mac-only fixes for shared `Form` chrome that the Catalyst Mac idiom lays out differently from
/// iOS. Kept beside `MacToolbarStyle` so every "this only looks wrong on the Mac" tweak lives in
/// one place, and each one is a no-op off Mac Catalyst so the iOS forms are untouched.
enum MacFormMetrics {
    /// Gap between a `DisclosureGroup`'s chevron and its label. On the Mac idiom the chevron is
    /// drawn on the *leading* edge with no gap at all, so the two glyphs collide ("›Advanced");
    /// iOS puts the chevron on the trailing edge and needs nothing.
    static let disclosureLabelGap: CGFloat = 6
}

extension View {
    /// Apply to a `DisclosureGroup`'s **label** so the label clears the leading chevron on the Mac.
    func macDisclosureLabel() -> some View {
        #if targetEnvironment(macCatalyst)
        padding(.leading, MacFormMetrics.disclosureLabelGap)
        #else
        self
        #endif
    }
}
