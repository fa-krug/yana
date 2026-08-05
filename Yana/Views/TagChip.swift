import SwiftUI

/// A small filled circle in a tag's color, for use as a leading marker in toggle/filter rows.
struct TagColorDot: View {
    let colorHex: String?

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex) ?? .accentColor)
            .frame(width: 12, height: 12)
    }
}

extension Color {
    /// Parses a `#RRGGBB` hex string (as stored on `Tag.colorHex`) into a `Color`.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
