import SwiftUI

/// Settings-app-style label: the SF Symbol sits in a small rounded, color-filled tile to the
/// left of the title. Works anywhere a `Label` does — list rows, `Toggle`, `Picker`,
/// `NavigationLink`, `DisclosureGroup` — via `.labelStyle(.tintedIcon(.orange))`.
struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    var size: CGFloat = 29

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            configuration.title
        }
    }
}

extension LabelStyle where Self == TintedIconLabelStyle {
    /// A label whose icon is shown in a rounded, tinted tile (Settings-app style).
    static func tintedIcon(_ tint: Color) -> TintedIconLabelStyle {
        TintedIconLabelStyle(tint: tint)
    }
}
