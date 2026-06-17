import SwiftUI

/// A small pill showing a tag's name tinted with its own color. Used wherever feed/article
/// tags are displayed, so a tag always reads in its color.
struct TagChip: View {
    let name: String
    let colorHex: String?

    private var color: Color { Color(hex: colorHex) ?? .accentColor }

    var body: some View {
        Text(name)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// A small filled circle in a tag's color, for use as a leading marker in toggle/filter rows.
struct TagColorDot: View {
    let colorHex: String?

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex) ?? .accentColor)
            .frame(width: 12, height: 12)
    }
}
