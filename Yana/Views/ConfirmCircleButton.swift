import SwiftUI

/// A prominent, circular checkmark button used as the confirmation/save action
/// in the top-right toolbar across every sheet.
///
/// Renders a white checkmark on the accent-colored circle so it stays legible
/// regardless of the accent color or color scheme.
struct ConfirmCircleButton: View {
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
        .disabled(isDisabled)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text("Done"))
    }
}
