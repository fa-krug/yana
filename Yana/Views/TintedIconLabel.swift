import SwiftUI

/// Settings-app-style label: the SF Symbol sits in a small rounded, color-filled tile to the
/// left of the title. Works anywhere a `Label` does — list rows, `Toggle`, `Picker`,
/// `NavigationLink`, `DisclosureGroup` — via `.labelStyle(.tintedIcon(.orange))`.
struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    var size: CGFloat = 29

    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        // System Settings rows carry no icon at all: a label is plain text in the leading column,
        // and the control sits opposite it. The iOS tile here was drawn into that same column, so
        // it overlapped the titles and pushed every control out of alignment. The sections are
        // shared with iOS, so the style -- not each call site -- is where the platform splits.
        configuration.title
        #else
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            configuration.title
        }
        #endif
    }
}

extension LabelStyle where Self == TintedIconLabelStyle {
    /// A label whose icon is shown in a rounded, tinted tile (Settings-app style).
    static func tintedIcon(_ tint: Color) -> TintedIconLabelStyle {
        TintedIconLabelStyle(tint: tint)
    }
}
